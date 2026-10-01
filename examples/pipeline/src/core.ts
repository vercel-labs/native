import { utf8Bytes } from "@native-sdk/core";

export interface Entry {
  readonly id: number;
  readonly title: Uint8Array;
  readonly description: Uint8Array;
  readonly meta: Uint8Array;
  readonly indicator: Uint8Array;
  readonly tone: Uint8Array;
  readonly connector: boolean;
}
export interface Model {
  readonly active: number;
  readonly selected: number;
  readonly reversed: boolean;
  readonly empty: boolean;
  readonly title: Uint8Array;
}
export type Msg =
  | { readonly kind: "next" }
  | { readonly kind: "previous" }
  | { readonly kind: "reset" }
  | { readonly kind: "reverse" }
  | { readonly kind: "toggle_empty" }
  | { readonly kind: "open"; readonly id: number };

export function initialModel(): Model {
  return { active: 0, selected: -1, reversed: false, empty: false, title: utf8Bytes("Review café") };
}
export function entries(model: Model): readonly Entry[] {
  if (model.empty) return [];
  const items: Entry[] = [
    { id: 10, title: utf8Bytes("Plan"), description: utf8Bytes("Define the change and its expected behavior."), meta: utf8Bytes("Design · ready"), indicator: utf8Bytes("1"), tone: utf8Bytes("primary"), connector: true },
    { id: 20, title: model.title, description: utf8Bytes("Inspect the native rendering, selection, and keyboard behavior."), meta: utf8Bytes("Review · résumé"), indicator: utf8Bytes("2"), tone: utf8Bytes("outline"), connector: true },
    { id: 30, title: utf8Bytes("Ship"), description: utf8Bytes(""), meta: utf8Bytes(""), indicator: utf8Bytes(""), tone: utf8Bytes("destructive"), connector: false },
  ];
  if (model.reversed) items.reverse();
  return items;
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "next": return { ...model, active: model.active < 4 ? model.active + 1 : model.active };
    case "previous": return { ...model, active: model.active > -1 ? model.active - 1 : model.active };
    case "reset": return initialModel();
    case "reverse": return { ...model, reversed: !model.reversed };
    case "toggle_empty": return { ...model, empty: !model.empty };
    case "open": return { ...model, selected: msg.id };
  }
}

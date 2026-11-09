import { utf8Bytes } from "@native-sdk/core";
export interface Choice {
  readonly id: number;
  readonly title: Uint8Array;
  readonly chosen: boolean;
  readonly disabled: boolean;
}
export interface Model {
  readonly selected: number;
  readonly nested: number;
  readonly changes: number;
  readonly reversed: boolean;
  readonly hidden: boolean;
}
export type Msg =
  | { readonly kind: "choose"; readonly id: number }
  | { readonly kind: "paper" }
  | { readonly kind: "reusable" }
  | { readonly kind: "reverse" }
  | { readonly kind: "hide" }
  | { readonly kind: "reset" };
export function initialModel(): Model {
  return { selected: 2, nested: 11, changes: 0, reversed: false, hidden: false };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "choose": return { ...model, selected: msg.id, changes: model.changes < 1000000 ? model.changes + 1 : model.changes };
    case "paper": return { ...model, nested: 11, changes: model.changes < 1000000 ? model.changes + 1 : model.changes };
    case "reusable": return { ...model, nested: 12, changes: model.changes < 1000000 ? model.changes + 1 : model.changes };
    case "reverse": return { ...model, reversed: !model.reversed };
    case "hide": return { ...model, hidden: !model.hidden };
    case "reset": return initialModel();
  }
}

export function choices(model: Model): readonly Choice[] {
  const items: Choice[] = [
    { id: 1, title: utf8Bytes("Standard"), chosen: model.selected === 1, disabled: false },
    { id: 9, title: utf8Bytes("Unavailable"), chosen: false, disabled: true },
  ];
  if (!model.hidden) items.push({ id: 2, title: utf8Bytes("Priority café"), chosen: model.selected === 2, disabled: false });
  const express = { id: 3, title: utf8Bytes("Express"), chosen: model.selected === 3, disabled: false };
  if (model.reversed) items.unshift(express); else items.push(express);
  return items;
}

import { utf8Bytes } from "@native-sdk/core";
export interface Tab {
  readonly id: number;
  readonly title: Uint8Array;
  readonly chosen: boolean;
  readonly disabled: boolean;
}
export interface Model {
  readonly selected: number;
  readonly secondary: number;
  readonly presses: number;
  readonly reversed: boolean;
  readonly hidden: boolean;
}
export type Msg =
  | { readonly kind: "choose"; readonly id: number }
  | { readonly kind: "summary" }
  | { readonly kind: "preferences" }
  | { readonly kind: "reverse" }
  | { readonly kind: "hide" }
  | { readonly kind: "reset" };
export function initialModel(): Model {
  return { selected: 2, secondary: 11, presses: 0, reversed: false, hidden: false };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "choose": return { ...model, selected: msg.id, presses: model.presses < 1000000 ? model.presses + 1 : model.presses };
    case "summary": return { ...model, secondary: 11, presses: model.presses < 1000000 ? model.presses + 1 : model.presses };
    case "preferences": return { ...model, secondary: 12, presses: model.presses < 1000000 ? model.presses + 1 : model.presses };
    case "reverse": return { ...model, reversed: !model.reversed };
    case "hide": return { ...model, hidden: !model.hidden };
    case "reset": return initialModel();
  }
}
export function tabs(model: Model): readonly Tab[] {
  const items: Tab[] = [
    { id: 1, title: utf8Bytes("Overview"), chosen: model.selected === 1, disabled: false },
    { id: 9, title: utf8Bytes("Unavailable"), chosen: false, disabled: true },
  ];
  if (!model.hidden) items.push({ id: 2, title: utf8Bytes("Activity café"), chosen: model.selected === 2, disabled: false });
  const settings = { id: 3, title: utf8Bytes("Settings"), chosen: model.selected === 3, disabled: false };
  if (model.reversed) items.unshift(settings); else items.push(settings);
  return items;
}

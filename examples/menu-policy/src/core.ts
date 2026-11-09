import { utf8Bytes } from "@native-sdk/core";

export interface Choice {
  readonly id: number;
  readonly title: Uint8Array;
  readonly selected: boolean;
  readonly disabled: boolean;
}
export interface Model {
  readonly selected: number;
  readonly environment: number;
  readonly pickerOpen: boolean;
  readonly actionsOpen: boolean;
  readonly environmentOpen: boolean;
  readonly presses: number;
  readonly lastAction: Uint8Array;
  readonly reversed: boolean;
  readonly hidden: boolean;
  readonly empty: boolean;
}
export type Msg =
  | { readonly kind: "choose"; readonly id: number }
  | { readonly kind: "toggle_picker" }
  | { readonly kind: "close_picker" }
  | { readonly kind: "toggle_actions" }
  | { readonly kind: "close_actions" }
  | { readonly kind: "duplicate" }
  | { readonly kind: "rename" }
  | { readonly kind: "download" }
  | { readonly kind: "toggle_environment" }
  | { readonly kind: "close_environment" }
  | { readonly kind: "production" }
  | { readonly kind: "staging" }
  | { readonly kind: "reverse" }
  | { readonly kind: "hide" }
  | { readonly kind: "empty" }
  | { readonly kind: "reset" };
export const viewUnbound = ["reversed", "hidden"] as const;
export function initialModel(): Model {
  return { selected: 2, environment: 101, pickerOpen: false, actionsOpen: false, environmentOpen: false,
    presses: 0, lastAction: utf8Bytes("None"), reversed: false, hidden: false, empty: false };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "choose": return { ...model, selected: msg.id, pickerOpen: false };
    case "toggle_picker": return { ...model, pickerOpen: !model.pickerOpen, actionsOpen: false, environmentOpen: false };
    case "close_picker": return { ...model, pickerOpen: false };
    case "toggle_actions": return { ...model, actionsOpen: !model.actionsOpen, pickerOpen: false, environmentOpen: false };
    case "close_actions": return { ...model, actionsOpen: false };
    case "duplicate": return { ...model, actionsOpen: false, presses: model.presses < 1000000 ? model.presses + 1 : model.presses, lastAction: utf8Bytes("Duplicate") };
    case "rename": return { ...model, actionsOpen: false, presses: model.presses < 1000000 ? model.presses + 1 : model.presses, lastAction: utf8Bytes("Rename") };
    case "download": return { ...model, actionsOpen: false, presses: model.presses < 1000000 ? model.presses + 1 : model.presses, lastAction: utf8Bytes("Download") };
    case "toggle_environment": return { ...model, environmentOpen: !model.environmentOpen, pickerOpen: false, actionsOpen: false };
    case "close_environment": return { ...model, environmentOpen: false };
    case "production": return { ...model, environment: 101, environmentOpen: false };
    case "staging": return { ...model, environment: 102, environmentOpen: false };
    case "reverse": return { ...model, reversed: !model.reversed };
    case "hide": return { ...model, hidden: !model.hidden };
    case "empty": return { ...model, empty: !model.empty };
    case "reset": return initialModel();
  }
}
export function choices(model: Model): readonly Choice[] {
  if (model.empty) return [];
  const rows: Choice[] = [
    { id: 1, title: utf8Bytes("Inbox"), selected: model.selected === 1, disabled: false },
    { id: 2, title: utf8Bytes("Review café"), selected: model.selected === 2, disabled: false },
    { id: 3, title: utf8Bytes("Unavailable"), selected: false, disabled: true },
    { id: 4, title: utf8Bytes("Release"), selected: model.selected === 4, disabled: false },
    { id: 5, title: utf8Bytes("Archive"), selected: model.selected === 5, disabled: false },
  ];
  const visible = rows.filter((row) => !model.hidden || row.id !== 2);
  if (model.reversed) return visible.map((_, index) => visible[visible.length - index - 1]!);
  return visible;
}
export function selectedTitle(model: Model): Uint8Array {
  switch (model.selected) {
    case 1: return utf8Bytes("Inbox");
    case 2: return utf8Bytes("Review café");
    case 4: return utf8Bytes("Release");
    case 5: return utf8Bytes("Archive");
    default: return utf8Bytes("Choose queue");
  }
}
export function environmentTitle(model: Model): Uint8Array {
  return model.environment === 101 ? utf8Bytes("Production") : utf8Bytes("Staging");
}

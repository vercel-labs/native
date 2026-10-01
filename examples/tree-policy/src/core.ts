import { utf8Bytes } from "@native-sdk/core";
export interface FolderRow {
  readonly id: number;
  readonly title: Uint8Array;
  readonly level: number;
  readonly chosen: boolean;
  readonly disabled: boolean;
}
export interface Model {
  readonly selected: number;
  readonly secondary: number;
  readonly presses: number;
  readonly expanded: boolean;
  readonly nestedExpanded: boolean;
  readonly reversed: boolean;
  readonly hidden: boolean;
}
export type Msg =
  | { readonly kind: "choose"; readonly id: number }
  | { readonly kind: "expand" }
  | { readonly kind: "expand_nested" }
  | { readonly kind: "archive" }
  | { readonly kind: "drafts" }
  | { readonly kind: "reverse" }
  | { readonly kind: "hide" }
  | { readonly kind: "reset" };
export const viewUnbound = ["reversed", "hidden"] as const;
export function initialModel(): Model {
  return { selected: 1, secondary: 101, presses: 0, expanded: true, nestedExpanded: true, reversed: false, hidden: false };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "choose": return { ...model, selected: msg.id, presses: model.presses < 1000000 ? model.presses + 1 : model.presses };
    case "expand": return { ...model, expanded: !model.expanded };
    case "expand_nested": return { ...model, nestedExpanded: !model.nestedExpanded };
    case "archive": return { ...model, secondary: 101 };
    case "drafts": return { ...model, secondary: 102 };
    case "reverse": return { ...model, reversed: !model.reversed };
    case "hide": return { ...model, hidden: !model.hidden };
    case "reset": return initialModel();
  }
}
export function children(model: Model): readonly FolderRow[] {
  const rows: FolderRow[] = [];
  if (!model.hidden) rows.push({ id: 11, title: utf8Bytes("Core café.ts"), level: 2, chosen: model.selected === 11, disabled: false });
  rows.push({ id: 19, title: utf8Bytes("Unavailable.ts"), level: 2, chosen: false, disabled: true });
  const view = { id: 12, title: utf8Bytes("App.native"), level: 2, chosen: model.selected === 12, disabled: false };
  if (model.reversed) rows.unshift(view); else rows.push(view);
  return rows;
}
export function sourceId(model: Model): number { return 1; }
export function readmeId(model: Model): number { return 2; }
export function assetsId(model: Model): number { return 3; }
export function iconId(model: Model): number { return 31; }
export function fontId(model: Model): number { return 32; }

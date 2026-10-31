import { utf8Bytes } from "@native-sdk/core";
export interface Item {
  readonly id: number;
  readonly title: Uint8Array;
  readonly detail: Uint8Array;
  readonly selected: boolean;
  readonly disabled: boolean;
}
export interface Model {
  readonly selected: number;
  readonly secondary: number;
  readonly nested: number;
  readonly presses: number;
  readonly reversed: boolean;
  readonly hidden: boolean;
  readonly empty: boolean;
}
export type Msg =
  | { readonly kind: "choose"; readonly id: number }
  | { readonly kind: "inbox" }
  | { readonly kind: "later" }
  | { readonly kind: "pinned" }
  | { readonly kind: "archive" }
  | { readonly kind: "reverse" }
  | { readonly kind: "hide" }
  | { readonly kind: "empty" }
  | { readonly kind: "reset" };
export const viewUnbound = ["reversed", "hidden"] as const;
export function initialModel(): Model {
  return { selected: 1, secondary: 101, nested: 201, presses: 0, reversed: false, hidden: false, empty: false };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "choose": return { ...model, selected: msg.id, presses: model.presses < 1000000 ? model.presses + 1 : model.presses };
    case "inbox": return { ...model, secondary: 101 };
    case "later": return { ...model, secondary: 102 };
    case "pinned": return { ...model, nested: 201 };
    case "archive": return { ...model, nested: 202 };
    case "reverse": return { ...model, reversed: !model.reversed };
    case "hide": return { ...model, hidden: !model.hidden };
    case "empty": return { ...model, empty: !model.empty };
    case "reset": return initialModel();
  }
}
export function items(model: Model): readonly Item[] {
  if (model.empty) return [];
  const rows: Item[] = [
    { id: 1, title: utf8Bytes("Build plan"), detail: utf8Bytes("Outline the next release"), selected: model.selected === 1, disabled: false },
    { id: 2, title: utf8Bytes("Review café"), detail: utf8Bytes("Check the proposed changes"), selected: model.selected === 2, disabled: false },
    { id: 3, title: utf8Bytes("Unavailable item"), detail: utf8Bytes("Waiting for access"), selected: false, disabled: true },
    { id: 4, title: utf8Bytes("Update docs"), detail: utf8Bytes("Explain the new behavior"), selected: model.selected === 4, disabled: false },
    { id: 5, title: utf8Bytes("Ship release"), detail: utf8Bytes("Publish when ready"), selected: model.selected === 5, disabled: false },
    { id: 6, title: utf8Bytes("Follow up"), detail: utf8Bytes("Collect feedback"), selected: model.selected === 6, disabled: false },
  ];
  const visible = rows.filter((item) => !model.hidden || item.id !== 2);
  if (model.reversed) return visible.map((_, index) => visible[visible.length - index - 1]!);
  return visible;
}

import { utf8Bytes } from "@native-sdk/core";

export interface Section {
  readonly id: number;
  readonly title: Uint8Array;
  readonly body: Uint8Array;
  readonly open: boolean;
  readonly disabled: boolean;
}
export interface Model {
  readonly sections: readonly Section[];
  readonly localOpen: boolean;
  readonly nestedOpen: boolean;
  readonly changes: number;
  readonly actions: number;
  readonly refreshes: number;
  readonly reversed: boolean;
  readonly hidden: boolean;
  readonly empty: boolean;
}
export type Msg =
  | { readonly kind: "toggle_section"; readonly id: number }
  | { readonly kind: "toggle_local" }
  | { readonly kind: "toggle_nested" }
  | { readonly kind: "open_all" }
  | { readonly kind: "close_all" }
  | { readonly kind: "action" }
  | { readonly kind: "reverse" }
  | { readonly kind: "hide" }
  | { readonly kind: "empty" }
  | { readonly kind: "refresh" }
  | { readonly kind: "reset" };
export const viewUnbound = ["sections", "reversed", "hidden"] as const;
export function initialModel(): Model {
  return {
    sections: [
      { id: 1, title: utf8Bytes("Account café"), body: utf8Bytes("Manage your profile and account settings."), open: false, disabled: false },
      { id: 2, title: utf8Bytes("Notifications"), body: utf8Bytes("Choose the updates you want to receive."), open: false, disabled: false },
      { id: 3, title: utf8Bytes("Unavailable"), body: utf8Bytes("This section is disabled."), open: false, disabled: true },
    ],
    localOpen: false, nestedOpen: false, changes: 0, actions: 0, refreshes: 0,
    reversed: false, hidden: false, empty: false,
  };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "toggle_section": return { ...model,
      sections: model.sections.map((row) => row.id === msg.id && !row.disabled ? { ...row, open: !row.open } : row),
      changes: model.changes < 1000000 ? model.changes + 1 : model.changes };
    case "toggle_local": return { ...model, localOpen: !model.localOpen, changes: model.changes < 1000000 ? model.changes + 1 : model.changes };
    case "toggle_nested": return { ...model, nestedOpen: !model.nestedOpen, changes: model.changes < 1000000 ? model.changes + 1 : model.changes };
    case "open_all": return { ...model, sections: model.sections.map((row) => row !== undefined && !row.disabled ? { ...row, open: true } : row) };
    case "close_all": return { ...model, sections: model.sections.map((row) => row !== undefined ? { ...row, open: false } : row) };
    case "action": return { ...model, actions: model.actions < 1000000 ? model.actions + 1 : model.actions };
    case "reverse": return { ...model, reversed: !model.reversed };
    case "hide": return { ...model, hidden: !model.hidden };
    case "empty": return { ...model, empty: !model.empty };
    case "refresh": return { ...model, refreshes: model.refreshes < 1000000 ? model.refreshes + 1 : model.refreshes };
    case "reset": return initialModel();
  }
}
export function visibleSections(model: Model): readonly Section[] {
  if (model.empty) return [];
  const rows = model.sections.filter((row) => !model.hidden || row.id !== 1);
  if (model.reversed) return rows.map((_, index) => rows[rows.length - index - 1]!);
  return rows;
}

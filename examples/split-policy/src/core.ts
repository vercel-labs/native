import { utf8Bytes } from "@native-sdk/core";

export interface Preview {
  readonly id: number;
  readonly title: Uint8Array;
  readonly fraction: number;
  readonly disabled: boolean;
}
export interface Model {
  readonly workspace: number;
  readonly sidebar: number;
  readonly editor: number;
  readonly locked: boolean;
  readonly reversed: boolean;
  readonly hidden: boolean;
  readonly empty: boolean;
  readonly widePreview: boolean;
  readonly resizes: number;
  readonly refreshes: number;
}
export type Msg =
  | { readonly kind: "sidebar_resized"; readonly sidebarFraction: number }
  | { readonly kind: "editor_resized"; readonly editorFraction: number }
  | { readonly kind: "preset" }
  | { readonly kind: "refresh" }
  | { readonly kind: "lock" }
  | { readonly kind: "reverse" }
  | { readonly kind: "hide" }
  | { readonly kind: "empty" }
  | { readonly kind: "preview_preset" }
  | { readonly kind: "new_workspace" };

// These fields are consumed by the derived preview list.
export const viewUnbound = ["reversed", "hidden", "widePreview"] as const;

export function initialModel(): Model {
  return { workspace: 0, sidebar: 0.24, editor: 0.58, locked: false,
    reversed: false, hidden: false, empty: false, widePreview: false, resizes: 0, refreshes: 0 };
}
export function sidebarPercent(model: Model): number { return Math.round(model.sidebar * 100); }
export function editorPercent(model: Model): number { return Math.round(model.editor * 100); }
export function previews(model: Model): readonly Preview[] {
  if (model.empty) return [];
  const notes: Preview = { id: 1, title: utf8Bytes("Notes"), fraction: model.widePreview ? 0.7 : 0.4, disabled: model.locked };
  const review: Preview = { id: 2, title: utf8Bytes("Review"), fraction: 0.55, disabled: true };
  if (model.hidden) return [review];
  return model.reversed ? [review, notes] : [notes, review];
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "sidebar_resized": return { ...model, sidebar: msg.sidebarFraction, resizes: model.resizes < 1000000 ? model.resizes + 1 : model.resizes };
    case "editor_resized": return { ...model, editor: msg.editorFraction, resizes: model.resizes < 1000000 ? model.resizes + 1 : model.resizes };
    case "preset": return { ...model, sidebar: 0.3, editor: 0.45 };
    case "refresh": return { ...model, refreshes: model.refreshes < 1000000 ? model.refreshes + 1 : model.refreshes };
    case "lock": return { ...model, locked: !model.locked };
    case "reverse": return { ...model, reversed: !model.reversed };
    case "hide": return { ...model, hidden: !model.hidden };
    case "empty": return { ...model, empty: !model.empty };
    case "preview_preset": return { ...model, widePreview: !model.widePreview };
    case "new_workspace": return { ...initialModel(), workspace: model.workspace < 1000000 ? model.workspace + 1 : 0 };
  }
}

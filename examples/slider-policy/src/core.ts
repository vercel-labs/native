import { utf8Bytes } from "@native-sdk/core";

export interface Track {
  readonly id: number;
  readonly title: Uint8Array;
  readonly value: number;
  readonly disabled: boolean;
}
export interface Model {
  readonly master: number;
  readonly preview: number;
  readonly trimSource: number;
  readonly changes: number;
  readonly trimChanges: number;
  readonly refreshes: number;
  readonly profile: number;
  readonly preset: boolean;
  readonly locked: boolean;
  readonly reversed: boolean;
  readonly hidden: boolean;
  readonly empty: boolean;
}
export type Msg =
  | { readonly kind: "master_changed"; readonly value: number }
  | { readonly kind: "preview_changed"; readonly fraction: number }
  | { readonly kind: "trim_changed" }
  | { readonly kind: "preset" }
  | { readonly kind: "lock" }
  | { readonly kind: "refresh" }
  | { readonly kind: "reverse" }
  | { readonly kind: "hide" }
  | { readonly kind: "empty" }
  | { readonly kind: "new_mixer" };
export const viewUnbound = ["master", "preview", "trimSource", "preset", "reversed", "hidden"] as const;
export function initialModel(): Model {
  return { master: 0.35, preview: 0.5, trimSource: 0.25, changes: 0, trimChanges: 0,
    refreshes: 0, profile: 0, preset: false, locked: false, reversed: false, hidden: false, empty: false };
}
export function update(model: Model, msg: Msg): Model {
  const changes = model.changes < 1000000 ? model.changes + 1 : model.changes;
  switch (msg.kind) {
    case "master_changed": return model.locked ? model : { ...model, master: Math.max(0.0, Math.min(1.0, msg.value)), changes };
    case "preview_changed": return model.locked ? model : { ...model, preview: Math.max(0.0, Math.min(1.0, msg.fraction)), changes };
    case "trim_changed": return model.locked ? model : { ...model, trimChanges: model.trimChanges < 1000000 ? model.trimChanges + 1 : model.trimChanges };
    case "preset": return { ...model, preset: !model.preset, master: model.preset ? 0.35 : 0.8,
      preview: model.preset ? 0.5 : 0.2, trimSource: model.preset ? 0.25 : 0.65 };
    case "lock": return { ...model, locked: !model.locked };
    case "refresh": return { ...model, refreshes: model.refreshes < 1000000 ? model.refreshes + 1 : model.refreshes };
    case "reverse": return { ...model, reversed: !model.reversed };
    case "hide": return { ...model, hidden: !model.hidden };
    case "empty": return { ...model, empty: !model.empty };
    case "new_mixer": return { ...initialModel(), profile: model.profile < 1000000 ? model.profile + 1 : model.profile };
  }
}
function percent(value: number): number {
  let count = 0;
  let threshold = 0.005;
  while (count < 100 && threshold <= value) { count += 1; threshold += 0.01; }
  return count;
}
export function masterPercent(model: Model): number { return percent(model.master); }
export function previewPercent(model: Model): number { return percent(model.preview); }
export function trimSourcePercent(model: Model): number { return percent(model.trimSource); }
export function tracks(model: Model): readonly Track[] {
  if (model.empty) return [];
  const rows: Track[] = [
    { id: 1, title: utf8Bytes("Acoustic café"), value: model.trimSource, disabled: model.locked },
    { id: 2, title: utf8Bytes("Bass"), value: 0.6, disabled: model.locked },
    { id: 3, title: utf8Bytes("Managed monitor"), value: 0.4, disabled: true },
  ];
  const visible = rows.filter(row => !model.hidden || row.id !== 1);
  if (model.reversed) return visible.map((_, index) => visible[visible.length - index - 1]!);
  return visible;
}

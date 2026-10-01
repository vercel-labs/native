import { utf8Bytes } from "@native-sdk/core";

export interface Choice {
  readonly id: number;
  readonly title: Uint8Array;
  readonly checked: boolean;
  readonly disabled: boolean;
}
export interface Model {
  readonly product: boolean;
  readonly digest: boolean;
  readonly notifications: boolean;
  readonly sync: boolean;
  readonly compact: boolean;
  readonly changes: number;
  readonly refreshes: number;
  readonly profile: number;
  readonly reversed: boolean;
  readonly hidden: boolean;
  readonly empty: boolean;
  readonly locked: boolean;
}
export type Msg =
  | { readonly kind: "check"; readonly id: number }
  | { readonly kind: "notifications" }
  | { readonly kind: "sync" }
  | { readonly kind: "compact" }
  | { readonly kind: "reverse" }
  | { readonly kind: "hide" }
  | { readonly kind: "empty" }
  | { readonly kind: "lock" }
  | { readonly kind: "refresh" }
  | { readonly kind: "new_profile" };
export const viewUnbound = ["product", "digest", "reversed", "hidden"] as const;
export function initialModel(): Model {
  return { product: false, digest: true, notifications: true, sync: false, compact: true,
    changes: 0, refreshes: 0, profile: 0, reversed: false, hidden: false, empty: false, locked: false };
}
export function update(model: Model, msg: Msg): Model {
  const changes = model.changes < 1000000 ? model.changes + 1 : model.changes;
  switch (msg.kind) {
    case "check":
      if (model.locked) return model;
      if (msg.id === 1) return { ...model, product: !model.product, changes };
      if (msg.id === 2) return { ...model, digest: !model.digest, changes };
      return model;
    case "notifications": return model.locked ? model : { ...model, notifications: !model.notifications, changes };
    case "sync": return model.locked ? model : { ...model, sync: !model.sync, changes };
    case "compact": return model.locked ? model : { ...model, compact: !model.compact, changes };
    case "reverse": return { ...model, reversed: !model.reversed };
    case "hide": return { ...model, hidden: !model.hidden };
    case "empty": return { ...model, empty: !model.empty };
    case "lock": return { ...model, locked: !model.locked };
    case "refresh": return { ...model, refreshes: model.refreshes < 1000000 ? model.refreshes + 1 : model.refreshes };
    case "new_profile": return { ...initialModel(), profile: model.profile < 1000000 ? model.profile + 1 : model.profile };
  }
}
export function choices(model: Model): readonly Choice[] {
  if (model.empty) return [];
  const rows: Choice[] = [
    { id: 1, title: utf8Bytes("Product café updates"), checked: model.product, disabled: model.locked },
    { id: 2, title: utf8Bytes("Weekly digest"), checked: model.digest, disabled: model.locked },
    { id: 3, title: utf8Bytes("Managed reports"), checked: true, disabled: true },
  ];
  const visible = rows.filter((row) => !model.hidden || row.id !== 1);
  if (model.reversed) return visible.map((_, index) => visible[visible.length - index - 1]!);
  return visible;
}

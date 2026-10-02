import { utf8Bytes } from "@native-sdk/core";
import { type ScrollState } from "@native-sdk/core/events";

export type Axes = "vertical" | "both";
export type Edges = "none" | "rubber_band";
export interface Model {
  readonly desk: number;
  readonly boardX: number;
  readonly boardY: number;
  readonly shelfX: number;
  readonly axes: Axes;
  readonly edges: Edges;
  readonly reversed: boolean;
  readonly hidden: boolean;
  readonly empty: boolean;
  readonly changes: number;
  readonly refreshes: number;
  readonly opened: number;
}
export interface Entry { readonly id: number; readonly title: Uint8Array }
export interface ReadingPanel { readonly id: number; readonly title: Uint8Array; readonly source: number }

export type Msg =
  | { readonly kind: "board_scrolled"; readonly scroll: ScrollState }
  | { readonly kind: "shelf_scrolled"; readonly scroll: ScrollState }
  | { readonly kind: "origin" } | { readonly kind: "middle" } | { readonly kind: "far_corner" }
  | { readonly kind: "x_preset" } | { readonly kind: "y_preset" }
  | { readonly kind: "refresh" } | { readonly kind: "reverse" }
  | { readonly kind: "hide_reading" } | { readonly kind: "empty" }
  | { readonly kind: "axis" } | { readonly kind: "edges" } | { readonly kind: "new_desk" }
  | { readonly kind: "open"; readonly id: number };

export const viewUnbound = ["reversed", "hidden"] as const;
export function initialModel(): Model {
  return { desk: 0, boardX: 0.5, boardY: 0.5, shelfX: 0.5, axes: "both", edges: "none",
    reversed: false, hidden: false, empty: false, changes: 0, refreshes: 0, opened: 0 };
}
export function entries(model: Model): readonly Entry[] {
  const result: Entry[] = [];
  if (!model.empty) for (let i = 1; i <= 8; i++) result.push({ id: i, title: utf8Bytes(`Project ${i}`) });
  return result;
}
export function panels(model: Model): readonly ReadingPanel[] {
  if (model.empty) return [];
  const reading: ReadingPanel = { id: 1, title: utf8Bytes("Reading notes"), source: 18.5 };
  const archive: ReadingPanel = { id: 2, title: utf8Bytes("Archive notes"), source: 32.5 };
  if (model.hidden) return [archive];
  return model.reversed ? [archive, reading] : [reading, archive];
}
export function boardXLabel(model: Model): number { return Math.round(model.boardX); }
export function boardYLabel(model: Model): number { return Math.round(model.boardY); }
export function shelfLabel(model: Model): number { return Math.round(model.shelfX); }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "board_scrolled": return { ...model, boardX: msg.scroll.offsetX, boardY: msg.scroll.offsetY,
      changes: model.changes < 1000000 ? model.changes + 1 : model.changes };
    case "shelf_scrolled": return { ...model, shelfX: msg.scroll.offsetX,
      changes: model.changes < 1000000 ? model.changes + 1 : model.changes };
    case "origin": return { ...model, boardX: 0, boardY: 0, shelfX: 0 };
    case "middle": return { ...model, boardX: 140.5, boardY: 180.5, shelfX: 120.5 };
    case "far_corner": return { ...model, boardX: 1000000.5, boardY: 1000000.5, shelfX: 1000000.5 };
    case "x_preset": return { ...model, boardX: 75.25 };
    case "y_preset": return { ...model, boardY: 95.75 };
    case "refresh": return { ...model, refreshes: model.refreshes < 1000000 ? model.refreshes + 1 : model.refreshes };
    case "reverse": return { ...model, reversed: !model.reversed };
    case "hide_reading": return { ...model, hidden: !model.hidden };
    case "empty": return { ...model, empty: !model.empty };
    case "axis": return { ...model, axes: model.axes === "both" ? "vertical" : "both" };
    case "edges": return { ...model, edges: model.edges === "none" ? "rubber_band" : "none" };
    case "new_desk": return { ...initialModel(), desk: model.desk < 1000000 ? model.desk + 1 : model.desk };
    case "open": return { ...model, opened: msg.id };
  }
}

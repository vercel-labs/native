import { Cmd, asciiBytes, windowDescriptor } from "@native-sdk/core";
import type { WindowDescriptor } from "@native-sdk/core/events";

export interface Model {
  readonly open: boolean;
  readonly compact: boolean;
  readonly reverse: boolean;
  readonly alternateClose: boolean;
  readonly count: number;
  readonly closes: number;
  readonly lastClose: Uint8Array;
}
export type Msg =
  | { readonly kind: "open" } | { readonly kind: "close" }
  | { readonly kind: "compact" } | { readonly kind: "reverse" }
  | { readonly kind: "route" } | { readonly kind: "bump" }
  | { readonly kind: "panel_closed" } | { readonly kind: "alternate_closed" };

export function initialModel(): [Model, Cmd<Msg>] {
  return [{ open: false, compact: false, reverse: false, alternateClose: false,
    count: 0, closes: 0, lastClose: asciiBytes("No panel closed yet.") }, Cmd.none];
}
export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "open": return [{ ...model, open: true }, Cmd.none];
    case "close": return [{ ...model, open: false }, Cmd.none];
    case "compact": return [{ ...model, compact: !model.compact }, Cmd.none];
    case "reverse": return [{ ...model, reverse: !model.reverse }, Cmd.none];
    case "route": return [{ ...model, alternateClose: !model.alternateClose }, Cmd.none];
    case "bump": return [{ ...model, count: model.count < 999999 ? model.count + 1 : model.count }, Cmd.none];
    case "panel_closed": return [{ ...model, open: false, closes: model.closes < 999999 ? model.closes + 1 : model.closes,
      lastClose: asciiBytes("Panel close received.") }, Cmd.none];
    case "alternate_closed": return [{ ...model, open: false, closes: model.closes < 999999 ? model.closes + 1 : model.closes,
      lastClose: asciiBytes("Alternate close received.") }, Cmd.none];
  }
}
export function windows(model: Model): readonly WindowDescriptor[] {
  if (!model.open) return [];
  const command = model.alternateClose ? asciiBytes("panel.alternate") : asciiBytes("panel.closed");
  const overview = windowDescriptor({ label: asciiBytes("overview"), canvasLabel: asciiBytes("overview-canvas"), title: asciiBytes("Overview"), width: 360, height: 260, onCloseCommand: command });
  const notes = windowDescriptor({ label: asciiBytes("notes"), canvasLabel: asciiBytes("notes-canvas"), title: asciiBytes("Notes"), width: 360, height: 260, onCloseCommand: command });
  const activity = windowDescriptor({ label: asciiBytes("activity"), canvasLabel: asciiBytes("activity-canvas"), title: asciiBytes("Activity"), width: 360, height: 260, onCloseCommand: command });
  const inspector = windowDescriptor({ label: asciiBytes("inspector"), canvasLabel: asciiBytes("inspector-canvas"), title: asciiBytes("Inspector"), width: 360, height: 260, onCloseCommand: command });
  if (model.compact) return model.reverse ? [inspector, overview] : [overview, inspector];
  return model.reverse ? [activity, notes, overview] : [overview, notes, activity];
}
export function commandMsg(name: string): Msg | null {
  if (name === "panel.closed") return { kind: "panel_closed" };
  if (name === "panel.alternate") return { kind: "alternate_closed" };
  return null;
}
export const viewUnbound = ["open", "compact", "reverse", "alternateClose", "panel_closed", "alternate_closed"] as const;

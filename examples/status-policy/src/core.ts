import { Cmd, asciiBytes } from "@native-sdk/core";
import type { StatusItemDescriptor, StatusItemMenuItem } from "@native-sdk/core/events";

export interface Model {
  readonly present: boolean;
  readonly compact: boolean;
  readonly reverse: boolean;
  readonly visible: boolean;
  readonly styled: boolean;
  readonly alternate: boolean;
  readonly count: number;
  readonly opens: number;
  readonly stampedMs: number;
  readonly last: Uint8Array;
}
export type Msg =
  | { readonly kind: "presence" } | { readonly kind: "compact" }
  | { readonly kind: "reverse" } | { readonly kind: "visibility" }
  | { readonly kind: "style" } | { readonly kind: "route" }
  | { readonly kind: "bump" } | { readonly kind: "other_bump" }
  | { readonly kind: "opened" } | { readonly kind: "activation" }
  | { readonly kind: "alternate_activation" } | { readonly kind: "stamp" }
  | { readonly kind: "stamped"; readonly at: number };
export function initialModel(): Model {
  return { present: true, compact: false, reverse: false, visible: true,
    styled: false, alternate: false, count: 0, opens: 0, stampedMs: -1,
    last: asciiBytes("Choose an action in the window or menu bar.") };
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "presence": return { ...model, present: !model.present };
    case "compact": return { ...model, compact: !model.compact };
    case "reverse": return { ...model, reverse: !model.reverse };
    case "visibility": return { ...model, visible: !model.visible };
    case "style": return { ...model, styled: !model.styled };
    case "route": return { ...model, alternate: !model.alternate };
    case "bump": return { ...model, count: model.count < 999999 ? model.count + 1 : model.count, last: asciiBytes("Session menu received.") };
    case "other_bump": return { ...model, count: model.count < 999999 ? model.count + 1 : model.count, last: asciiBytes("Control menu received.") };
    case "opened": return { ...model, opens: model.opens < 999999 ? model.opens + 1 : model.opens };
    case "activation": return { ...model, last: asciiBytes("Primary activation received.") };
    case "alternate_activation": return { ...model, last: asciiBytes("Alternate activation received.") };
    case "stamp": return [model, Cmd.now("stamped")];
    case "stamped": return { ...model, stampedMs: msg.at };
  }
}
function row(label: Uint8Array, command: Uint8Array, enabled: boolean): StatusItemMenuItem {
  return { id: 1, label, command, separator: false, enabled,
    detail: asciiBytes(""), role: "command", key: asciiBytes(""),
    modifiers: { primary: false, command: false, control: false, option: false, shift: false } };
}
export function statusItems(model: Model): readonly StatusItemDescriptor[] {
  if (!model.present) return [];
  const session: StatusItemDescriptor = {
    id: 100, visible: model.visible, iconPath: asciiBytes(""),
    tooltip: model.alternate ? asciiBytes("Alternate session route") : asciiBytes("Workspace sessions"),
    activationCommand: asciiBytes("session.activate"),
    alternateActivationCommand: asciiBytes("session.alternate"), openCommand: asciiBytes("session.open"),
    presentation: { title: model.styled ? asciiBytes("SESSIONS +") : asciiBytes("SESSIONS"),
      width: model.styled ? 116 : 92, tone: "normal", iconOpacity: 1,
      monospaced: model.styled, fontSize: model.styled ? 14 : 12,
      fontWeight: model.styled ? "semibold" : "regular" },
    items: [row(model.alternate ? asciiBytes("Add via control route") : asciiBytes("Add session"),
      model.alternate ? asciiBytes("control.add") : asciiBytes("session.add"), true),
      { ...row(asciiBytes("Menu opens"), asciiBytes(""), false), id: 2, role: "hero",
        metric: { primaryText: asciiBytes("Shared count"), secondaryText: asciiBytes("One app model"), accessibilityLabel: asciiBytes("Workspace metric") } }],
  };
  const control: StatusItemDescriptor = {
    id: 200, visible: true, iconPath: asciiBytes(""), tooltip: asciiBytes("Workspace controls"),
    activationCommand: asciiBytes(""), alternateActivationCommand: asciiBytes(""), openCommand: asciiBytes(""),
    presentation: { title: asciiBytes("DESK"), width: 58, tone: "normal", iconOpacity: 1, monospaced: true },
    items: [row(asciiBytes("Add from controls"), asciiBytes("control.add"), true)],
  };
  const notes: StatusItemDescriptor = {
    id: 300, visible: true, iconPath: asciiBytes(""), tooltip: asciiBytes("Workspace notes"),
    activationCommand: asciiBytes(""), alternateActivationCommand: asciiBytes(""), openCommand: asciiBytes(""),
    presentation: { title: asciiBytes("NOTES"), width: 62, tone: "normal", iconOpacity: 1, monospaced: false },
    items: [row(asciiBytes("Hide all items"), asciiBytes("workspace.hide"), true)],
  };
  if (model.compact) return model.reverse ? [control, session] : [session, control];
  return model.reverse ? [notes, control, session] : [session, control, notes];
}
export function commandMsg(name: string): Msg | null {
  if (name === "session.add") return { kind: "bump" };
  if (name === "control.add") return { kind: "other_bump" };
  if (name === "workspace.hide") return { kind: "presence" };
  if (name === "session.open") return { kind: "opened" };
  if (name === "session.activate") return { kind: "activation" };
  if (name === "session.alternate") return { kind: "alternate_activation" };
  return null;
}
export const viewUnbound = ["present", "compact", "reverse", "visible", "styled", "alternate", "other_bump", "opened", "activation", "alternate_activation", "stamped"] as const;

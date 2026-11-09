import { utf8Bytes } from "@native-sdk/core";
import { applyTextInputEvent, type TextInputEvent, type TextEditState } from "@native-sdk/core/text";

export interface Editor {
  readonly text: Uint8Array;
  readonly anchor: number;
  readonly focus: number;
  readonly compStart: number;
  readonly compEnd: number;
}
export interface Model {
  readonly desk: number;
  readonly subject: Editor;
  readonly draft: Editor;
  readonly chat: Editor;
  readonly scratchSource: Uint8Array;
  readonly scratchAlternate: boolean;
  readonly submitted: Uint8Array;
  readonly submits: number;
  readonly refreshes: number;
  readonly sendOnEnter: boolean;
  readonly locked: boolean;
  readonly hidden: boolean;
}
export type Msg =
  | { readonly kind: "subject_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "draft_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "chat_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "publish" }
  | { readonly kind: "send" }
  | { readonly kind: "refresh" }
  | { readonly kind: "enter_mode" }
  | { readonly kind: "lock" }
  | { readonly kind: "hide" }
  | { readonly kind: "restore_note" }
  | { readonly kind: "scratch_source" }
  | { readonly kind: "new_desk" };

function editor(text: Uint8Array): Editor {
  return { text: text, anchor: 0, focus: 0, compStart: -1, compEnd: -1 };
}
export const viewUnbound = ["hidden", "scratchAlternate"] as const;
export function noteVisible(model: Model): boolean { return !model.hidden; }
export function initialModel(): Model {
  return { desk: 0, subject: editor(utf8Bytes("Field notes")),
    draft: editor(utf8Bytes("Café observations\nA quiet place to write.")),
    chat: editor(utf8Bytes("Hello")), scratchSource: utf8Bytes("Scratch café\nA local draft."), scratchAlternate: false,
    submitted: utf8Bytes("Nothing sent yet"),
    submits: 0, refreshes: 0, sendOnEnter: true, locked: false, hidden: false };
}
function edit(value: Editor, event: TextInputEvent): Editor {
  const state: TextEditState = { text: value.text, selection: { anchor: value.anchor, focus: value.focus },
    composition: value.compStart >= 0 ? { start: value.compStart, end: value.compEnd } : null };
  const next = applyTextInputEvent(state, event, 4096);
  if (next === null) return value;
  const start = next.composition !== null ? next.composition.start : -1;
  const end = next.composition !== null ? next.composition.end : -1;
  return { text: next.text, anchor: next.selection.anchor, focus: next.selection.focus,
    compStart: start >= -1 && start <= 4096 ? Math.trunc(start) : -1,
    compEnd: end >= -1 && end <= 4096 ? Math.trunc(end) : -1 };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "subject_edit": return { ...model, subject: edit(model.subject, msg.edit) };
    case "draft_edit": return { ...model, draft: edit(model.draft, msg.edit) };
    case "chat_edit": return { ...model, chat: edit(model.chat, msg.edit) };
    case "publish": return { ...model, submitted: model.draft.text, submits: model.submits < 1000000 ? model.submits + 1 : model.submits };
    case "send": return { ...model, submitted: model.chat.text, submits: model.submits < 1000000 ? model.submits + 1 : model.submits };
    case "refresh": return { ...model, refreshes: model.refreshes < 1000000 ? model.refreshes + 1 : model.refreshes };
    case "enter_mode": return { ...model, sendOnEnter: !model.sendOnEnter };
    case "lock": return { ...model, locked: !model.locked };
    case "hide": return { ...model, hidden: !model.hidden };
    case "restore_note": return { ...model, draft: editor(utf8Bytes("Restored café\nA fresh draft from the app.")) };
    case "scratch_source": return { ...model, scratchAlternate: !model.scratchAlternate,
      scratchSource: model.scratchAlternate ? utf8Bytes("Scratch café\nA local draft.") : utf8Bytes("Fresh 日本\nAnother local draft.") };
    case "new_desk": return { ...initialModel(), desk: model.desk < 1000000 ? model.desk + 1 : 0 };
  }
}

import { utf8Bytes } from "@native-sdk/core";
import { applyTextInputEvent, type TextInputEvent } from "@native-sdk/core/text";

export interface Draft {
  readonly text: Uint8Array;
  readonly anchor: number;
  readonly focus: number;
  readonly compStart: number;
  readonly compEnd: number;
}
export interface Model {
  readonly workbench: number;
  readonly typescript: Draft;
  readonly python: Draft;
  readonly refreshes: number;
  readonly numbered: boolean;
  readonly hidden: boolean;
}
export type Msg =
  | { readonly kind: "edit_typescript"; readonly edit: TextInputEvent }
  | { readonly kind: "edit_python"; readonly edit: TextInputEvent }
  | { readonly kind: "spaces" }
  | { readonly kind: "tabs" }
  | { readonly kind: "refresh" }
  | { readonly kind: "numbers" }
  | { readonly kind: "hide" }
  | { readonly kind: "new_workbench" };

function draft(text: Uint8Array): Draft {
  return { text, anchor: 0, focus: 0, compStart: -1, compEnd: -1 };
}
export const viewUnbound = ["hidden"] as const;
export function typescriptVisible(model: Model): boolean { return !model.hidden; }
export function initialModel(): Model {
  return { workbench: 0,
    typescript: draft(utf8Bytes("function greet() {\n    return 'café';\n}\n")),
    python: draft(utf8Bytes("def greet():\n\treturn '日本'\n")),
    refreshes: 0, numbered: true, hidden: false };
}
function edit(value: Draft, event: TextInputEvent): Draft {
  const next = applyTextInputEvent({ text: value.text, selection: { anchor: value.anchor, focus: value.focus },
    composition: value.compStart >= 0 ? { start: value.compStart, end: value.compEnd } : null }, event, 16384);
  if (next === null) return value;
  const start = next.composition !== null ? next.composition.start : -1;
  const end = next.composition !== null ? next.composition.end : -1;
  return { text: next.text, anchor: next.selection.anchor, focus: next.selection.focus,
    compStart: start >= -1 && start <= 16384 ? Math.trunc(start) : -1,
    compEnd: end >= -1 && end <= 16384 ? Math.trunc(end) : -1 };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "edit_typescript": return { ...model, typescript: edit(model.typescript, msg.edit) };
    case "edit_python": return { ...model, python: edit(model.python, msg.edit) };
    case "spaces": return { ...model, typescript: draft(utf8Bytes("function greet() {\n    return 'café';\n}\n")) };
    case "tabs": return { ...model, typescript: draft(utf8Bytes("function greet() {\n\treturn 'café';\n}\n")) };
    case "refresh": return { ...model, refreshes: model.refreshes < 1000000 ? model.refreshes + 1 : model.refreshes };
    case "numbers": return { ...model, numbered: !model.numbered };
    case "hide": return { ...model, hidden: !model.hidden };
    case "new_workbench": return { ...initialModel(), workbench: model.workbench < 1000000 ? model.workbench + 1 : 0 };
  }
}

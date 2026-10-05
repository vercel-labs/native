import { asciiBytes, utf8Bytes } from "@native-sdk/core";
import { applyTextInputEvent, clampedInsertEvent, type TextEditState, type TextInputEvent } from "@native-sdk/core/text";
import type { ChromeInsets, ChromeButtons } from "@native-sdk/core/events";

export type Filter = "all" | "active" | "done";
export interface Task { readonly id: number; readonly title: Uint8Array; readonly done: boolean; }
export interface Model {
  readonly tasks: readonly Task[];
  readonly next_id: number;
  readonly filter: Filter;
  readonly chrome_leading: number;
  readonly header_height: number;
  readonly draft_buffer: TextEditState;
  readonly draft_truncated: boolean;
}
export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "toggle"; readonly id: number }
  | { readonly kind: "set_filter"; readonly filter: Filter }
  | { readonly kind: "clear_done" }
  | { readonly kind: "draft_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "chrome_changed"; readonly insets: ChromeInsets; readonly buttons: ChromeButtons; readonly tabsProjected: boolean };

export const chromeMsg = "chrome_changed";
export const viewUnbound = ["tasks", "next_id", "draft_buffer", "draft_truncated"] as const;
function emptyDraft(): TextEditState {
  return { text: asciiBytes(""), selection: { anchor: 0, focus: 0 }, composition: null };
}
export function initialModel(): Model {
  return { tasks: [
    { id: 1, title: utf8Bytes("Prove the ui builder end to end"), done: false },
    { id: 2, title: utf8Bytes("Rewrite gpu-dashboard with it"), done: false },
    { id: 3, title: utf8Bytes("Record the authoring decisions"), done: false },
  ], next_id: 4, filter: "all", chrome_leading: 0, header_height: 52, draft_buffer: emptyDraft(), draft_truncated: false };
}
function trimSpaces(text: Uint8Array): Uint8Array {
  let start = 0;
  let end = text.length;
  while (start < end && text[start] === 32) start++;
  while (end > start && text[end - 1] === 32) end--;
  return text.subarray(start, end);
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "add": {
      const entered = !draftEmpty(model);
      const text = entered ? trimSpaces(model.draft_buffer.text) : utf8Bytes(`Task ${model.next_id}`);
      if (model.tasks.length >= 64) return entered ? { ...model, draft_buffer: emptyDraft() } : model;
      return { ...model, tasks: [...model.tasks, { id: model.next_id, title: text.subarray(0, 32), done: false }],
        next_id: (model.next_id + 1) >>> 0, draft_buffer: entered ? emptyDraft() : model.draft_buffer };
    }
    case "toggle": return { ...model, tasks: model.tasks.map(task => task !== undefined && task.id === msg.id ? { ...task, done: !task.done } : task) };
    case "set_filter": return { ...model, filter: msg.filter };
    case "clear_done": return { ...model, tasks: model.tasks.filter(task => !task.done) };
    case "draft_edit": {
      const edited = applyTextInputEvent(model.draft_buffer, msg.edit, 32);
      if (edited !== null) return { ...model, draft_buffer: edited, draft_truncated: false };
      const clamped = clampedInsertEvent(model.draft_buffer, msg.edit, 32);
      const next = clamped === null ? null : applyTextInputEvent(model.draft_buffer, clamped, 32);
      return { ...model, draft_buffer: next === null ? model.draft_buffer : next, draft_truncated: true };
    }
    case "chrome_changed": return { ...model, chrome_leading: msg.insets.left, header_height: Math.max(52, msg.insets.top) };
  }
}
export function draft(model: Model): Uint8Array { return model.draft_buffer.text; }
export function draftEmpty(model: Model): boolean {
  for (const byte of model.draft_buffer.text) if (byte !== 32 && byte !== 9) return false;
  return true;
}
export function filters(model: Model): readonly Filter[] { return ["all", "active", "done"]; }
export function openCount(model: Model): number { return model.tasks.filter(task => !task.done).length; }
export function doneCount(model: Model): number { return model.tasks.length - openCount(model); }
export function hasDone(model: Model): boolean { return doneCount(model) > 0; }
export function visible(model: Model): readonly Task[] {
  return model.tasks.filter(task => model.filter === "all" || (model.filter === "done" ? task.done : !task.done));
}

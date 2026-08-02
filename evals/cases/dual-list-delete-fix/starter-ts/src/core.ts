// The tasks app core: seeded tasks, open/done toggling, filter chips, a
// draft entry riding the toolkit's text-input events, and derived counts.
// Written in the app-core TypeScript subset — see
// .claude/skills/ts-core/SKILL.md and README.md.

import { asciiBytes } from "@native-sdk/core";
import { applyTextInputEvent, trimAsciiSpaces, type TextEditState, type TextInputEvent } from "@native-sdk/core/text";

export type Bytes = Uint8Array;
export type Filter = "all" | "open" | "done";

export interface Task {
  readonly id: number;
  readonly title: Bytes;
  readonly done: boolean;
}

export interface Model {
  readonly tasks: readonly Task[];
  readonly nextId: number;
  readonly filter: Filter;
  readonly draft: TextEditState;
  /** The rows the list shows, refreshed whenever the tasks change. */
  readonly visible: readonly Task[];
}

export type Msg =
  | { readonly kind: "draft_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "add" }
  | { readonly kind: "toggle"; readonly id: number }
  | { readonly kind: "delete"; readonly id: number }
  | { readonly kind: "set_filter"; readonly filter: Filter };

export const viewUnbound = ["draft", "visible", "tasks", "nextId"] as const;

const DRAFT_CAPACITY = 64;

const EMPTY_DRAFT: TextEditState = {
  text: new Uint8Array(0),
  selection: { anchor: 0, focus: 0 },
  composition: null,
};

function filteredTasks(tasks: readonly Task[], filter: Filter): readonly Task[] {
  if (filter === "open") return tasks.filter((t) => !t.done);
  if (filter === "done") return tasks.filter((t) => t.done);
  return tasks;
}

export function initialModel(): Model {
  const tasks: readonly Task[] = [
    { id: 1, title: asciiBytes("Ship the fix"), done: false },
    { id: 2, title: asciiBytes("Write the tests"), done: true },
    { id: 3, title: asciiBytes("Update the docs"), done: false },
  ];
  return { tasks: tasks, nextId: 4, filter: "all", draft: EMPTY_DRAFT, visible: filteredTasks(tasks, "all") };
}

export function visibleTasks(model: Model): readonly Task[] {
  return model.visible;
}

export function filterChoices(model: Model): readonly Filter[] {
  return ["all", "open", "done"];
}

export function openCount(model: Model): number {
  return model.tasks.filter((t) => !t.done).length;
}

export function draftText(model: Model): Bytes {
  return model.draft.text;
}

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "draft_edit": {
      const draft = applyTextInputEvent(model.draft, msg.edit, DRAFT_CAPACITY);
      if (draft === null) return model;
      return { ...model, draft: draft };
    }
    case "add": {
      const title = trimAsciiSpaces(model.draft.text);
      if (title.length === 0) return model;
      const tasks: readonly Task[] = [...model.tasks, { id: model.nextId, title: title, done: false }];
      return {
        ...model,
        tasks: tasks,
        nextId: model.nextId + 1,
        draft: EMPTY_DRAFT,
        visible: filteredTasks(tasks, model.filter),
      };
    }
    case "toggle": {
      const tasks = model.tasks.map((t) => (t.id === msg.id ? { ...t, done: !t.done } : t));
      return { ...model, tasks: tasks, visible: filteredTasks(tasks, model.filter) };
    }
    case "delete":
      return { ...model, tasks: model.tasks.filter((t) => t.id !== msg.id) };
    case "set_filter":
      return { ...model, filter: msg.filter, visible: filteredTasks(model.tasks, msg.filter) };
  }
}

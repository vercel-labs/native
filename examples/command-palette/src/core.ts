// The command palette example: a task list whose every action is a
// palette command. Cmd+Shift+P (the exact shortcut id the
// keyboard-shortcuts docs use as their example) toggles the palette,
// typing filters, plain ArrowUp/Down move the selection, Enter runs.
//
// The arrow navigation rides the edit-derivation seam: a single-line
// field maps unmodified ArrowUp/Down to caret start/end jumps, and the
// derivation stamps that edit onto the dispatched event — so on-input
// hears `move_caret` and the palette treats it as list navigation
// instead of applying it to the query draft. No runtime changes, no
// app-level key fallback: the palette is pure userland.

import { Sub, asciiBytes } from "@native-sdk/core";
import { type ScrollState } from "@native-sdk/core/events";
import {
  applyTextInputEvent,
  clampedInsertEvent,
  containsIgnoreCase,
  orderIgnoreCase,
  type TextEditState,
  type TextInputEvent,
} from "@native-sdk/core/text";

export type Bytes = Uint8Array;

const MAX_QUERY = 96;

interface Draft {
  readonly bytes: Bytes;
  readonly anchor: number;
  readonly focus: number;
  readonly compStart: number;
  readonly compEnd: number;
}

function draftInit(): Draft {
  return { bytes: asciiBytes(""), anchor: 0, focus: 0, compStart: -1, compEnd: -1 };
}

function draftState(d: Draft): TextEditState {
  return {
    text: d.bytes,
    selection: { anchor: d.anchor, focus: d.focus },
    composition: d.compStart >= 0 ? { start: d.compStart, end: d.compEnd } : null,
  };
}

function draftFrom(next: TextEditState): Draft {
  return {
    bytes: next.text,
    anchor: next.selection.anchor,
    focus: next.selection.focus,
    compStart: next.composition !== null ? next.composition.start : -1,
    compEnd: next.composition !== null ? next.composition.end : -1,
  };
}

function draftApply(d: Draft, event: TextInputEvent): Draft {
  const state = draftState(d);
  const next = applyTextInputEvent(state, event, MAX_QUERY);
  if (next === null) {
    const clamped = clampedInsertEvent(state, event, MAX_QUERY);
    if (clamped === null) return d;
    const nextClamped = applyTextInputEvent(state, clamped, MAX_QUERY);
    if (nextClamped === null) return d;
    return draftFrom(nextClamped);
  }
  return draftFrom(next);
}

// ------------------------------------------------------------ tasks

export interface Task {
  readonly id: number;
  readonly title: Bytes;
  readonly done: boolean;
}

function sampleTasks(): readonly Task[] {
  return [
    { id: 1, title: asciiBytes("Review the markup diff"), done: false },
    { id: 2, title: asciiBytes("Ship the changelog fragment"), done: false },
    { id: 3, title: asciiBytes("Answer the design thread"), done: true },
    { id: 4, title: asciiBytes("Rebuild the docs site"), done: false },
    { id: 5, title: asciiBytes("Tag the release"), done: false },
  ];
}

// ------------------------------------------------------------ commands

// Static commands own ids below 100; every open task contributes a
// dynamic "Complete:" command at 100 + task id — the palette's rows are
// DERIVED from app data, which is the whole point of a palette.
const CMD_CLEAR = 1;
const CMD_RESTORE = 2;
const CMD_SORT = 3;
const CMD_TASK_BASE = 100;

const TITLE_CLEAR = asciiBytes("Clear completed tasks");
const TITLE_RESTORE = asciiBytes("Restore sample tasks");
const TITLE_SORT = asciiBytes("Sort tasks A to Z");
const PREFIX_COMPLETE = asciiBytes("Complete:");
const PREFIX_NONE = asciiBytes("");

// Palette results geometry: uniform rows inside the dialog's scroll.
const PALETTE_ROW_EXTENT = 37.5;
const PALETTE_VIEWPORT = 235.75;

function paletteScrollFor(offset: number, rowTop: number): number {
  const bottom = rowTop + PALETTE_ROW_EXTENT;
  if (rowTop < offset) return rowTop;
  if (bottom > offset + PALETTE_VIEWPORT) return bottom - PALETTE_VIEWPORT;
  return offset;
}

// ------------------------------------------------------------ model

export interface Model {
  readonly tasks: readonly Task[];
  readonly paletteOpen: boolean;
  readonly paletteDraft: Draft;
  readonly paletteSelected: number;
  readonly paletteScroll: number;
  readonly status: Bytes;
}

export type Msg =
  | { readonly kind: "toggle_palette" }
  | { readonly kind: "close_palette" }
  | { readonly kind: "palette_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "palette_exec" }
  | { readonly kind: "palette_run"; readonly id: number }
  | { readonly kind: "palette_scrolled"; readonly scroll: ScrollState }
  | { readonly kind: "task_toggle"; readonly id: number };

export function initialModel(): Model {
  return {
    tasks: sampleTasks(),
    paletteOpen: false,
    paletteDraft: draftInit(),
    paletteSelected: 0,
    paletteScroll: 0 * PALETTE_ROW_EXTENT,
    status: asciiBytes("Cmd+Shift+P for commands"),
  };
}

export function commandMsg(name: string): Msg | null {
  if (name === "command.palette") return { kind: "toggle_palette" };
  if (name === "command.dismiss") return { kind: "close_palette" };
  return null;
}

// ------------------------------------------------------------ update

interface CommandRow {
  readonly id: number;
  readonly prefix: Bytes;
  readonly title: Bytes;
}

function visibleCommands(model: Model): readonly CommandRow[] {
  const query = model.paletteDraft.bytes;
  const out: CommandRow[] = [];
  const statics: readonly CommandRow[] = [
    { id: CMD_CLEAR, prefix: PREFIX_NONE, title: TITLE_CLEAR },
    { id: CMD_RESTORE, prefix: PREFIX_NONE, title: TITLE_RESTORE },
    { id: CMD_SORT, prefix: PREFIX_NONE, title: TITLE_SORT },
  ];
  for (let i = 0; i < statics.length; i++) {
    if (query.length > 0 && !containsIgnoreCase(statics[i].title, query)) continue;
    out[out.length] = statics[i];
  }
  for (let i = 0; i < model.tasks.length; i++) {
    const task = model.tasks[i];
    if (task.done) continue;
    if (query.length > 0 && !containsIgnoreCase(task.title, query)) continue;
    out[out.length] = { id: CMD_TASK_BASE + task.id, prefix: PREFIX_COMPLETE, title: task.title };
  }
  return out;
}

function paletteStep(model: Model, delta: number): Model {
  const count = visibleCommands(model).length;
  if (count === 0) return model;
  let next = model.paletteSelected + delta;
  if (next < 0) next = count - 1;
  if (next >= count) next = 0;
  let rowTop = 0 * PALETTE_ROW_EXTENT;
  for (let i = 0; i < next; i++) rowTop = rowTop + PALETTE_ROW_EXTENT;
  return { ...model, paletteSelected: next, paletteScroll: paletteScrollFor(model.paletteScroll, rowTop) };
}

function setTaskDone(tasks: readonly Task[], id: number, done: boolean): readonly Task[] {
  const out: Task[] = [];
  for (let i = 0; i < tasks.length; i++) {
    const task = tasks[i];
    out[out.length] = task.id === id ? { id: task.id, title: task.title, done: done } : task;
  }
  return out;
}

function runCommand(model: Model, id: number): Model {
  const closed: Model = {
    ...model,
    paletteOpen: false,
    paletteDraft: draftInit(),
    paletteSelected: 0,
    paletteScroll: 0 * PALETTE_ROW_EXTENT,
  };
  if (id === CMD_CLEAR) {
    const open: Task[] = [];
    for (let i = 0; i < model.tasks.length; i++) {
      if (!model.tasks[i].done) open[open.length] = model.tasks[i];
    }
    return { ...closed, tasks: open, status: asciiBytes("Cleared completed tasks") };
  }
  if (id === CMD_RESTORE) {
    return { ...closed, tasks: sampleTasks(), status: asciiBytes("Restored sample tasks") };
  }
  if (id === CMD_SORT) {
    const sorted = model.tasks.slice();
    for (let i = 1; i < sorted.length; i++) {
      let j = i;
      while (j > 0 && orderIgnoreCase(sorted[j].title, sorted[j - 1].title) < 0) {
        const held = sorted[j];
        sorted[j] = sorted[j - 1];
        sorted[j - 1] = held;
        j = j - 1;
      }
    }
    return { ...closed, tasks: sorted, status: asciiBytes("Sorted tasks") };
  }
  if (id >= CMD_TASK_BASE) {
    return {
      ...closed,
      tasks: setTaskDone(model.tasks, id - CMD_TASK_BASE, true),
      status: asciiBytes("Completed a task"),
    };
  }
  return closed;
}

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "toggle_palette":
      if (model.paletteOpen) return { ...model, paletteOpen: false };
      return { ...model, paletteOpen: true, paletteDraft: draftInit(), paletteSelected: 0, paletteScroll: 0 * PALETTE_ROW_EXTENT };
    case "close_palette":
      return { ...model, paletteOpen: false };
    case "palette_edit": {
      // The seam in action: unmodified vertical arrows arrive as caret
      // start/end jumps — reinterpret them as list navigation. Extend
      // variants (shift held) stay text-selection edits and apply.
      const edit = msg.edit;
      if (edit.kind === "move_caret") {
        if (!edit.move.extend) {
          if (edit.move.direction === "end") return paletteStep(model, 1);
          if (edit.move.direction === "start") return paletteStep(model, -1);
        }
      }
      return { ...model, paletteDraft: draftApply(model.paletteDraft, edit), paletteSelected: 0, paletteScroll: 0 * PALETTE_ROW_EXTENT };
    }
    case "palette_exec": {
      const visible = visibleCommands(model);
      if (visible.length === 0) return model;
      const index = model.paletteSelected < visible.length ? model.paletteSelected : 0;
      return runCommand(model, visible[index].id);
    }
    case "palette_run":
      return runCommand(model, msg.id);
    case "palette_scrolled":
      return { ...model, paletteScroll: msg.scroll.offset };
    case "task_toggle": {
      let found = false;
      let wasDone = false;
      for (let i = 0; i < model.tasks.length; i++) {
        if (model.tasks[i].id === msg.id) {
          found = true;
          wasDone = model.tasks[i].done;
        }
      }
      if (!found) return model;
      return { ...model, tasks: setTaskDone(model.tasks, msg.id, !wasDone) };
    }
  }
}

export function subscriptions(model: Model): Sub<Msg> {
  return Sub.none;
}

// ------------------------------------------------------------ bindings

export interface PaletteRow {
  readonly id: number;
  readonly prefix: Bytes;
  readonly title: Bytes;
  readonly hasPrefix: boolean;
  readonly selected: boolean;
}

export function paletteRows(model: Model): readonly PaletteRow[] {
  const visible = visibleCommands(model);
  const rows: PaletteRow[] = [];
  for (let i = 0; i < visible.length; i++) {
    rows[rows.length] = {
      id: visible[i].id,
      prefix: visible[i].prefix,
      title: visible[i].title,
      hasPrefix: visible[i].prefix.length > 0,
      selected: i === model.paletteSelected,
    };
  }
  return rows;
}

export function paletteQuery(model: Model): Bytes {
  return model.paletteDraft.bytes;
}

export interface TaskRow {
  readonly id: number;
  readonly title: Bytes;
  readonly done: boolean;
}

export function taskRows(model: Model): readonly TaskRow[] {
  const rows: TaskRow[] = [];
  for (let i = 0; i < model.tasks.length; i++) {
    rows[rows.length] = { id: model.tasks[i].id, title: model.tasks[i].title, done: model.tasks[i].done };
  }
  return rows;
}

export function openCount(model: Model): number {
  let count = 0;
  for (let i = 0; i < model.tasks.length; i++) {
    if (!model.tasks[i].done) count = count + 1;
  }
  return count;
}

export function doneCount(model: Model): number {
  return model.tasks.length - openCount(model);
}

export function statusLine(model: Model): Bytes {
  return model.status;
}

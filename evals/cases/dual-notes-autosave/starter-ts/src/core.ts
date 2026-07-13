// The notes app core: three seeded notes, sidebar selection, and a body
// editor riding the toolkit's text-input events (the SDK text engine does
// the byte splicing). Written in the app-core TypeScript subset — see
// .claude/skills/ts-core/SKILL.md and README.md.

import { asciiBytes } from "@native-sdk/core";
import { applyTextInputEvent, type TextEditState, type TextInputEvent } from "@native-sdk/core/text";

export type Bytes = Uint8Array;

export interface Note {
  readonly id: number;
  readonly title: Bytes;
  readonly body: Bytes;
}

export interface Model {
  readonly notes: readonly Note[];
  readonly selectedId: number;
  /** The editor state over the SELECTED note's body (caret, selection). */
  readonly editor: TextEditState;
}

export type Msg =
  | { readonly kind: "select"; readonly id: number }
  | { readonly kind: "edit"; readonly edit: TextInputEvent };

// The editor is mirrored into the selected note on every edit; markup binds
// the helpers below, never the editor record itself.
export const viewUnbound = ["editor"] as const;

const BODY_CAPACITY = 256;

function editorFor(body: Bytes): TextEditState {
  return { text: body, selection: { anchor: body.length, focus: body.length }, composition: null };
}

export function initialModel(): Model {
  const notes: readonly Note[] = [
    { id: 1, title: asciiBytes("Groceries"), body: asciiBytes("milk, eggs") },
    { id: 2, title: asciiBytes("Ideas"), body: asciiBytes("native first") },
    { id: 3, title: asciiBytes("Standup"), body: asciiBytes("demo the panel") },
  ];
  return { notes: notes, selectedId: 1, editor: editorFor(notes[0].body) };
}

export function selectedTitle(model: Model): Bytes {
  const note = model.notes.find((n) => n.id === model.selectedId);
  return note === undefined ? new Uint8Array(0) : note.title;
}

export function editorText(model: Model): Bytes {
  return model.editor.text;
}

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "select": {
      const note = model.notes.find((n) => n.id === msg.id);
      if (note === undefined) return model;
      return { ...model, selectedId: msg.id, editor: editorFor(note.body) };
    }
    case "edit": {
      // A null result is the engine's capacity refusal: keep the old state.
      const editor = applyTextInputEvent(model.editor, msg.edit, BODY_CAPACITY);
      if (editor === null) return model;
      return {
        ...model,
        editor: editor,
        notes: model.notes.map((n) => (n.id === model.selectedId ? { ...n, body: editor.text } : n)),
      };
    }
  }
}

// Minimal attributed-editing dogfood: plain bytes + style runs, bold/italic
// toggles, GFM preview via text-attr helpers.

import { asciiBytes, utf8Bytes } from "@native-sdk/core";
import {
  type TextInputEvent,
  type TextSelection,
} from "@native-sdk/core/text";
import {
  applyAttributedTextInputEvent,
  attributedToMarkdown,
  deserializeStyleRuns,
  serializeStyleRuns,
  toggleStyleOnSelection,
  type AttributedEditState,
  type StyleFlag,
} from "@native-sdk/core/text-attr";

const CAPACITY = 8192;
const CARET0: TextSelection = { anchor: 0, focus: 0 };

export type Bytes = Uint8Array;

export interface Model {
  readonly draft: Bytes;
  readonly draftSel: TextSelection;
  readonly styles: Bytes;
  readonly status: Bytes;
}

export type Msg =
  | { readonly kind: "edit"; readonly edit: TextInputEvent }
  | { readonly kind: "bold" }
  | { readonly kind: "italic" }
  | { readonly kind: "strike" };

function attributedState(model: Model): AttributedEditState {
  return {
    text: model.draft,
    selection: model.draftSel,
    composition: null,
    runs: deserializeStyleRuns(model.styles),
  };
}

function toggle(model: Model, flag: StyleFlag): Model {
  const runs = toggleStyleOnSelection(
    deserializeStyleRuns(model.styles),
    model.draftSel,
    model.draft.length,
    flag,
  );
  return {
    ...model,
    styles: serializeStyleRuns(runs),
    status: asciiBytes(flag),
  };
}

export function initialModel(): Model {
  return {
    draft: utf8Bytes("Select words and tap Bold / Italic."),
    draftSel: CARET0,
    styles: new Uint8Array(0),
    status: asciiBytes("ready"),
  };
}

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "edit": {
      const next = applyAttributedTextInputEvent(
        attributedState(model),
        msg.edit,
        CAPACITY,
      );
      if (!next) return model;
      return {
        ...model,
        draft: next.text,
        draftSel: next.selection,
        styles: serializeStyleRuns(next.runs),
      };
    }
    case "bold":
      return toggle(model, "bold");
    case "italic":
      return toggle(model, "italic");
    case "strike":
      return toggle(model, "strikethrough");
  }
}

export function preview(model: Model): Bytes {
  return attributedToMarkdown(model.draft, deserializeStyleRuns(model.styles));
}

export function draft(model: Model): Bytes {
  return model.draft;
}

export function status(model: Model): Bytes {
  return model.status;
}

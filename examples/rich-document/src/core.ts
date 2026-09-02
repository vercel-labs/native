// Multi-block GFM dogfood: text_doc ops + one focused rich-textarea body.

import { asciiBytes, utf8Bytes } from "@native-sdk/core";
import {
  type TextInputEvent,
  type TextSelection,
} from "@native-sdk/core/text";
import {
  applyAttributedTextInputEvent,
  deserializeStyleRuns,
  serializeStyleRuns,
  toggleStyleOnSelection,
  type StyleFlag,
} from "@native-sdk/core/text-attr";
import {
  changeBlockKind,
  mergeWithPrevious,
  parseBlocks,
  serializeBlocks,
  splitBlock,
  type BlockKind,
  type DocBlock,
} from "@native-sdk/core/text-doc";

const CAPACITY = 8192;
const CARET0: TextSelection = { anchor: 0, focus: 0 };

export type Bytes = Uint8Array;

export interface BlockRow {
  readonly index: number;
  readonly kind_label: Bytes;
  readonly preview: Bytes;
  readonly marker: Bytes;
  readonly focused: boolean;
}

export interface Model {
  readonly blocks: readonly DocBlock[];
  readonly focus: number;
  readonly editorText: Bytes;
  readonly editorSel: TextSelection;
  readonly editorStyles: Bytes;
  readonly status: Bytes;
  readonly blockRows: readonly BlockRow[];
  readonly serialized: Bytes;
}

export type Msg =
  | { readonly kind: "edit"; readonly edit: TextInputEvent }
  | { readonly kind: "focus"; readonly index: number }
  | { readonly kind: "bold" }
  | { readonly kind: "italic" }
  | { readonly kind: "kind_h1" }
  | { readonly kind: "kind_h2" }
  | { readonly kind: "kind_p" }
  | { readonly kind: "kind_bullet" };

function kindLabel(kind: BlockKind): Bytes {
  switch (kind) {
    case "heading1":
      return asciiBytes("H1");
    case "heading2":
      return asciiBytes("H2");
    case "heading3":
      return asciiBytes("H3");
    case "bullet_item":
      return asciiBytes("*");
    case "numbered_item":
      return asciiBytes("1.");
    case "code_fence":
      return asciiBytes("code");
    case "paragraph":
      return asciiBytes("P");
  }
}

function markerFor(kind: BlockKind): Bytes {
  switch (kind) {
    case "bullet_item":
      return asciiBytes("*");
    case "numbered_item":
      return asciiBytes("1.");
    default:
      return asciiBytes("");
  }
}

function previewOf(text: Uint8Array): Bytes {
  if (text.length <= 48) {
    const out = new Uint8Array(text.length);
    out.set(text);
    return out;
  }
  return text.subarray(0, 48);
}

function copyBytes(b: Uint8Array): Bytes {
  const out = new Uint8Array(b.length);
  out.set(b);
  return out;
}

function buildRows(blocks: readonly DocBlock[], focus: number): BlockRow[] {
  const rows: BlockRow[] = [];
  const n = blocks.length;
  if (!(n >= 0) || !(n <= 256)) return rows;
  let fi = 0;
  if (focus >= 0 && focus < n) fi = Math.trunc(focus);
  for (let i = 0; i < n; i++) {
    const b = blocks[i]!;
    rows.push({
      index: i,
      kind_label: kindLabel(b.kind),
      preview: previewOf(b.text),
      marker: markerFor(b.kind),
      focused: i === fi,
    });
  }
  return rows;
}

function withBlocks(model: Model, blocks: readonly DocBlock[], focus: number): Model {
  const n = blocks.length;
  let clamped = 0;
  if (n >= 1 && n <= 256) {
    if (focus >= 0 && focus < n) clamped = Math.trunc(focus);
    else if (focus >= n) clamped = Math.trunc(n - 1);
  }
  const block = blocks[clamped]!;
  return {
    ...model,
    blocks,
    focus: clamped,
    editorText: copyBytes(block.text),
    editorSel: CARET0,
    editorStyles: new Uint8Array(0),
    blockRows: buildRows(blocks, clamped),
    serialized: serializeBlocks(blocks),
  };
}

function commitEditor(model: Model): Model {
  const blocks: DocBlock[] = [];
  for (let i = 0; i < model.blocks.length; i++) {
    const b = model.blocks[i]!;
    if (i === model.focus) {
      blocks.push({
        kind: b.kind,
        text: copyBytes(model.editorText),
        language: copyBytes(b.language),
      });
    } else {
      blocks.push({
        kind: b.kind,
        text: copyBytes(b.text),
        language: copyBytes(b.language),
      });
    }
  }
  return {
    ...model,
    blocks,
    blockRows: buildRows(blocks, model.focus),
    serialized: serializeBlocks(blocks),
  };
}

function setKind(model: Model, kind: BlockKind): Model {
  const committed = commitEditor(model);
  const next = changeBlockKind(committed.blocks, committed.focus, kind);
  if (!next) return model;
  return {
    ...withBlocks(committed, next, committed.focus),
    status: asciiBytes(kind),
  };
}

export function initialModel(): Model {
  const seed = utf8Bytes(
    "# Untitled\n\nWrite the next paragraph.\n\n- First bullet",
  );
  const blocks = parseBlocks(seed);
  const base: Model = {
    blocks,
    focus: 0,
    editorText: new Uint8Array(0),
    editorSel: CARET0,
    editorStyles: new Uint8Array(0),
    status: asciiBytes("ready"),
    blockRows: [],
    serialized: new Uint8Array(0),
  };
  return withBlocks(base, blocks, 0);
}

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "focus": {
      const committed = commitEditor(model);
      return withBlocks(committed, committed.blocks, msg.index);
    }
    case "edit": {
      if (
        msg.edit.kind === "insert_text" &&
        msg.edit.text.length === 1 &&
        msg.edit.text[0] === 10
      ) {
        const committed = commitEditor(model);
        const caret = committed.editorSel.focus;
        const split = splitBlock(committed.blocks, committed.focus, caret);
        if (!split) return model;
        return {
          ...withBlocks(committed, split, committed.focus + 1),
          status: asciiBytes("split"),
        };
      }
      if (
        msg.edit.kind === "delete_backward" &&
        model.editorSel.anchor === model.editorSel.focus &&
        model.editorSel.focus === 0 &&
        model.focus > 0
      ) {
        const committed = commitEditor(model);
        const prev = committed.blocks[committed.focus - 1]!;
        const rawLen = prev.text.length;
        let leftLen = 0;
        if (rawLen >= 0 && rawLen <= 8192) leftLen = Math.trunc(rawLen);
        const merged = mergeWithPrevious(committed.blocks, committed.focus);
        if (!merged) return model;
        const next = withBlocks(committed, merged, committed.focus - 1);
        return {
          ...next,
          editorSel: { anchor: leftLen, focus: leftLen },
          status: asciiBytes("merge"),
        };
      }
      const next = applyAttributedTextInputEvent(
        {
          text: model.editorText,
          selection: model.editorSel,
          composition: null,
          runs: deserializeStyleRuns(model.editorStyles),
        },
        msg.edit,
        CAPACITY,
      );
      if (!next) return model;
      const mid = {
        ...model,
        editorText: next.text,
        editorSel: next.selection,
        editorStyles: serializeStyleRuns(next.runs),
      };
      return commitEditor(mid);
    }
    case "bold":
    case "italic": {
      const flag: StyleFlag = msg.kind === "bold" ? "bold" : "italic";
      const runs = toggleStyleOnSelection(
        deserializeStyleRuns(model.editorStyles),
        model.editorSel,
        model.editorText.length,
        flag,
      );
      return {
        ...model,
        editorStyles: serializeStyleRuns(runs),
        status: asciiBytes(flag),
      };
    }
    case "kind_h1":
      return setKind(model, "heading1");
    case "kind_h2":
      return setKind(model, "heading2");
    case "kind_p":
      return setKind(model, "paragraph");
    case "kind_bullet":
      return setKind(model, "bullet_item");
  }
}

export type StyleFlag =
  | "bold"
  | "italic"
  | "underline"
  | "monospace"
  | "strikethrough";
export interface StyleFlags {
  readonly bold: boolean;
  readonly italic: boolean;
  readonly underline: boolean;
  readonly monospace: boolean;
  readonly strikethrough: boolean;
}
export interface StyleRun {
  readonly start: number;
  readonly end: number;
  readonly flags: StyleFlags;
}
export interface AttributedEditState {
  readonly text: Uint8Array;
  readonly selection: import("./text").TextSelection;
  readonly composition: { readonly start: number; readonly end: number } | null;
  readonly runs: readonly StyleRun[];
}
export declare const MAX_STYLE_RUNS: number;
export declare const EMPTY_STYLE_FLAGS: StyleFlags;
export declare function serializeStyleRuns(runs: readonly StyleRun[]): Uint8Array;
export declare function deserializeStyleRuns(bytes: Uint8Array): StyleRun[];
export declare function toggleStyleOnSelection(
  runs: readonly StyleRun[],
  selection: import("./text").TextSelection,
  textLen: number,
  flag: StyleFlag,
): StyleRun[];
export declare function applyAttributedTextInputEvent(
  state: AttributedEditState,
  event: import("./text").TextInputEvent,
  capacity: number,
): AttributedEditState | null;
export declare function attributedToMarkdown(
  text: Uint8Array,
  runs: readonly StyleRun[],
): Uint8Array;
export declare function pushStyleUndo(
  stack: readonly Uint8Array[],
  runs: readonly StyleRun[],
  maxDepth: number,
): Uint8Array[];
export declare function popStyleUndo(
  stack: readonly Uint8Array[],
): { stack: Uint8Array[]; runs: StyleRun[] } | null;

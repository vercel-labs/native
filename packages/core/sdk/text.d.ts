export interface TextRange {
    readonly start: number;
    readonly end: number;
}
export interface TextSelection {
    readonly anchor: number;
    readonly focus: number;
}
export type TextCaretDirection = "previous" | "next" | "previous_word" | "next_word" | "start" | "end";
export interface TextCaretMove {
    readonly direction: TextCaretDirection;
    readonly extend: boolean;
}
export type TextInputEvent = {
    readonly kind: "insert_text";
    readonly text: Uint8Array;
} | {
    readonly kind: "delete_backward";
} | {
    readonly kind: "delete_forward";
} | {
    readonly kind: "delete_word_backward";
} | {
    readonly kind: "delete_word_forward";
} | {
    readonly kind: "delete_to_start";
} | {
    readonly kind: "delete_to_line_start";
} | {
    readonly kind: "clear";
} | {
    readonly kind: "move_caret";
    readonly move: TextCaretMove;
} | {
    readonly kind: "set_selection";
    readonly selection: TextSelection;
} | {
    readonly kind: "set_composition";
    readonly text: Uint8Array;
    readonly cursor: number | null;
} | {
    readonly kind: "commit_composition";
} | {
    readonly kind: "cancel_composition";
};
export interface TextEditState {
    readonly text: Uint8Array;
    readonly selection: TextSelection;
    readonly composition: TextRange | null;
}
/** Indentation inserted by a code editor's plain Tab. Nonempty indented
 * lines vote for tabs or spaces; space widths 2–8 compete by divisibility,
 * with wider widths winning ties. A tied tab vote follows the caret's
 * current line. Unindented and ambiguous files use two spaces.
 */
export declare function codeIndentationInsertion(text: Uint8Array, caret: number): Uint8Array;
/** Parse one-based code diff lines, such as `2-4, 7`. Lines are unique,
 * retain author order, and range from 1 through 128. Empty ASCII-whitespace
 * text produces no lines; malformed pieces or descending ranges return null.
 * Decimal names accept a leading + and interior underscores, matching the
 * native markup parser. Returns a fresh array; source bytes are never changed.
 */
export declare function parseCodeLineNumberSpec(spec: Uint8Array): number[] | null;
export declare function sanitizedSingleLineTextInputEvent(event: TextInputEvent): TextInputEvent | null;
/** Select the word, whitespace run or punctuation cluster at a UTF-8 byte
 * offset. An offset at or beyond the end selects the trailing run.
 */
export declare function textWordSelectionAtOffset(text: Uint8Array, offset: number): TextSelection;
/** Select a hard-newline line without its LF or CRLF terminator. */
export declare function textLineSelectionAtOffset(text: Uint8Array, offset: number): TextSelection;
export declare function caretSelectionAt(anchor: number, focus: number): TextSelection;
export declare function applyTextInputEvent(state: TextEditState, event: TextInputEvent, capacity: number): TextEditState | null;
export declare function clampedInsertEvent(state: TextEditState, event: TextInputEvent, capacity: number): TextInputEvent | null;
export declare function containsIgnoreCase(haystack: Uint8Array, needle: Uint8Array): boolean;
export declare function orderIgnoreCase(a: Uint8Array, b: Uint8Array): number;
export declare function trimAsciiSpaces(text: Uint8Array): Uint8Array;

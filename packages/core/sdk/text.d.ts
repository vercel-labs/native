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
export declare function applyTextInputEvent(state: TextEditState, event: TextInputEvent, capacity: number): TextEditState | null;
export declare function clampedInsertEvent(state: TextEditState, event: TextInputEvent, capacity: number): TextInputEvent | null;
export declare function containsIgnoreCase(haystack: Uint8Array, needle: Uint8Array): boolean;
export declare function orderIgnoreCase(a: Uint8Array, b: Uint8Array): number;
export declare function trimAsciiSpaces(text: Uint8Array): Uint8Array;

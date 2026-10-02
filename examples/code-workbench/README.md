# Code Workbench

Two independent source drafts authored in TypeScript and Native markup, with
syntax highlighting, line numbers, selection, IME and Undo/Redo.

```sh
native dev
native test
```

Plain Tab inserts the draft's inferred indentation: tabs when tab-indented
lines dominate, otherwise a space width from two through eight. Ambiguous
sources use two spaces. Shift+Tab moves focus instead of changing the draft.
Enter inserts a newline. Each editor keeps its own Undo/Redo history.

Added lines and Removed lines accept one-based lists and ranges such as
`2-4, 7`, up to line 128. Apply diff decorates the TypeScript draft with
green/red washes and `+`/`-` markers. Invalid or overlapping lists keep the
last applied diff. Clear diff removes it. Markers stay outside source,
selection and clipboard bytes; changing annotations preserves Undo/Redo.

Use spaces and Use tabs replace the TypeScript source. Refresh keeps local
edits, selection and widget identities. Hide TypeScript preserves the
app-owned draft; New workbench starts fresh editors. Toggle line numbers
changes the gutter without adding digits to the source or clipboard text.
Long lines stay intact and scroll horizontally; overflowing drafts scroll
vertically.

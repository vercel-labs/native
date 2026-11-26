# draft

A document editor in plain HTML, CSS and TypeScript: a contenteditable article with a formatting
toolbar (paragraph style, bold/italic/underline, lists, clear formatting, undo/redo), a selection
readout, a link dialog that wraps the selection, keyboard shortcuts (Cmd+B/I/U, Cmd+S) and a draft
kept in localStorage.

## Build

```console
$ node ../../packages/cli/compiler/cli.ts build . -o build/editor
$ NATIVE_STEPS='frame 0 | print #word-count | dblclick #doc | print #selection-info' NATIVE_SNAPSHOT=editor.png ./build/editor
```

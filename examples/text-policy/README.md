# Writing Desk

A TypeScript and Native markup app with a multiline note, a message composer,
and a single-line subject. Text input uses the SDK's UTF-8 editor state and
supports selection, word navigation, deletion and IME composition.

```sh
native dev
native test
```

Enter adds a newline to the note. Cmd+Enter on macOS (Ctrl+Enter elsewhere)
publishes it. The message starts with Enter to send; Shift+Enter always adds
a line. Toggle Enter to send changes that setting without replacing the editor.
Refresh preserves text and widget identities; New desk starts a fresh draft.

Double-click selects a word, whitespace run, or punctuation cluster. Drag while
holding the second click to extend by whole runs. Triple-click selects the
whole subject or the clicked note line, excluding its newline. Shift extends
from the standing anchor; dragging back into the anchor run restores that run.

The editors keep UTF-8 byte boundaries and treat CRLF as one caret stop.
Undo and redo preserve selections; successive IME previews replace the active
composition, and committing a composition records one undoable edit.

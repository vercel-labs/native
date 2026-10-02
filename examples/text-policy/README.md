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
Undo restores the selection's direction as well as its byte range. Each editor
has its own history: editing another field keeps the first field's redo branch.
Canceling an empty composition keeps redo; committing a new edit replaces it.

Scratchpad keeps its edits locally: Refresh preserves the draft and active
composition, while Replace scratch supplies a new starting value. Restore
note replaces the app-owned note. Locking editors uses their authored values;
New desk starts every editor afresh.

Copy, cut, and paste use the system clipboard. Subject joins pasted lines by
removing CR/LF; Note, Message, and Scratchpad keep them. Single-line IME
previews use the same rule, including empty previews. Paste fits the view's
remaining text budget at a UTF-8 boundary after removing line breaks; undo
and redo restore retained bytes exactly.

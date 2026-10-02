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

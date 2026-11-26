# notes

A markdown notes app: a searchable list of notes on the left, a plain-text editor in the middle
and a live preview on the right. Notes are written to `localStorage` as you type, and the list,
the search field, the editor and the buttons come from React 19, Tailwind 4 and `@ui-sdk/react`.

## Build

```console
$ node ../../packages/cli/compiler/cli.ts build . -o build/notes
$ NATIVE_STEPS='frame 0 | click #new-note | click #body | type Hello | print #preview' NATIVE_SNAPSHOT=notes.png ./build/notes
```

The first run fills the list with a few starter notes. `NATIVE_STORAGE=/tmp/notes.json` points a
headless run at its own storage file.

## Styles

`style.css` is the Tailwind 4 build of `input.css`; regenerate it after editing the classes:

```console
$ npm run css
```

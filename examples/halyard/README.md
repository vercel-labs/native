# halyard

A team issue tracker: a dark sidebar of views and teams, a filterable list whose rows drag into a
new order, a detail pane with a checklist and comments, and a command palette on Command-K.
React 19 renders it and Tailwind 4 styles it. The buttons and fields come from `@ui-sdk/react`;
the palette's overlay, filtered list and arrow-key highlight are the page's own.

## Build

```console
$ node ../../packages/cli/compiler/cli.ts build . -o build/halyard
$ NATIVE_STEPS='frame 0 | frame 16 | key e | frame 16 | print #status' NATIVE_SNAPSHOT=halyard.png ./build/halyard
```

## Styles

`style.css` is the Tailwind 4 build of `input.css`; regenerate it after editing the classes:

```console
$ npm run css
```

Tailwind's scanner reads `app.tsx`, `icons.tsx`, `data.ts` and `index.html`, and the generated sheet
is what `native build` compiles.

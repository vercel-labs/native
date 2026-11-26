# kanban

A kanban board with four columns of task cards. Drag a card onto another column to move it, or
onto a card to drop it above that one; each column has a composer that takes a new card on Enter.
React 19 renders it, Tailwind 4 styles it, and the New card button comes from `@ui-sdk/react`.

## Build

```console
$ node ../../packages/cli/compiler/cli.ts build . -o build/kanban
$ NATIVE_STEPS='frame 0 | drag #card-k6 600 0 | print #board-status' NATIVE_SNAPSHOT=kanban.png ./build/kanban
```

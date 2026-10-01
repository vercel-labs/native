# List policy

A TypeScript work queue with composed rows, offscreen keyboard targets,
disabled items, independent and nested lists, and stable keyed identities.
Tab enters keyboard navigation; Up/Down move focus without wrapping.
Pointer entry stays quiet. Enter/Space activates a row. Home/End
preserve the currently visible edges. Selection stays in the app model.

```sh
native dev
native test
native test -Dtypescript-view=true
native build -Dtypescript-view=true
```

The compiled view uses scriptc for direct-sibling selection clearing and
keyboard traversal. Native retains geometry, scroll reveal, and rendering.

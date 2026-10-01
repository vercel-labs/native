# Tree policy

A TypeScript app with model-owned folder expansion, flat logical levels,
nested rows, disabled entries, independent trees, and stable keyed children.
Arrows and Home/End move selection through the tree; Left/Right collapse,
expand, and traverse parents or children. Enter/Space activates a row.

```sh
native dev
native test
native test -Dtypescript-view=true
native build -Dtypescript-view=true
```

The compiled view uses scriptc for tree scope, selection clearing, and
keyboard traversal. Native retains visibility, scroll reveal, and rendering.

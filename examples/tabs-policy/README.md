# Tabs policy

A TypeScript app with independent tab strips and model-owned panels. Left/Right moves focus between enabled visible triggers without wrapping; Home/End moves focus to the edges. Enter/Space activates the focused tab. Each trigger remains an ordinary Tab stop. Reverse preserves keyed identities; Hide activity removes the active trigger while retaining its model-owned panel.

```sh
native dev
native test -Dplatform=null
native test -Dplatform=null -Dtypescript-view=true
native build -Dtypescript-view=true
```

The compiled preview uses scriptc for direct button trigger lowering, selection clearing, and authored-order keyboard targets. Native retains geometry, visibility, focus presentation, and rendering. Rebuild after markup edits.

# Radio policy

A TypeScript app demonstrating single selection, nested radio groups, and roving keyboard focus. Arrow keys wrap within the nearest group; Home and End choose its edges. Tab enters at the selected radio and leaves the group as one stop. Disabled radios are skipped. Reverse preserves keyed identities; Hide priority removes the selected option.

```sh
native dev
native test -Dplatform=null
native test -Dplatform=null -Dtypescript-view=true
native build -Dtypescript-view=true
```

The compiled view preview uses scriptc for selection scope and focus policy. Native supplies retained tree and visibility information, applies selection, and reveals keyboard targets. Rebuild after markup changes.

# Menu policy

A TypeScript work queue picker, actions menu, and independent environment
picker. Open a menu, then use Up/Down and Home/End to move focus without
wrapping; Enter/Space activates, and Escape or an outside click dismisses.
Tab/Shift+Tab closes the menu and returns focus to the trigger; the next Tab
continues through ordinary controls. Picks and Escape also return focus.

```sh
native dev
native test
native test -Dtypescript-view=true
native build -Dtypescript-view=true
```

The compiled view uses scriptc for selected-row entry, keyboard traversal,
selection clearing, and the distinction between committed picker choices
and unchecked action menus. Native places overlays, applies focus, and renders.

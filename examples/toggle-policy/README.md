# Toggle policy

A TypeScript theme selector and independent formatting buttons. Left/Right
and Home/End move focus without changing selection or wrapping. Enter/Space
activates the focused toggle; Tab/Shift+Tab follows ordinary control order.

Theme selection is model-owned. Formatting buttons keep their independent
retained state through refreshes and theme changes. The theme rows support
keyed reversal, hide/restore, and empty/repopulate.

```sh
native dev
native test
native test -Dtypescript-view=true
native build -Dtypescript-view=true
```

The compiled view uses scriptc for toggle transitions, source/retained state
reconciliation, and toggle-group focus targets. Native applies state and
focus, checks visibility, and renders the controls.

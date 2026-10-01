# Checkable preferences

A TypeScript preferences app using checkboxes, switches, and a plain toggle.
Enter/Space, pointer clicks, and accessibility toggle actions change settings.
Tab/Shift+Tab follows ordinary control order and skips disabled settings.

Refresh keeps current choices. Lock settings disables editable controls without
changing the choices. Keyed email preferences support reversal, hide/restore,
and empty/repopulate. New profile mounts a fresh preference tree with defaults.

```sh
native dev
native test
native test -Dtypescript-view=true
native build -Dtypescript-view=true
```

The compiled view uses scriptc for activation and retained-state reconciliation.
Checkboxes, switches, and plain toggles preserve retained user state across
rebuilds; `checked` sets the initial state. Native keeps input routing, geometry,
focus application, accessibility, and switch-knob animation.

# Atlas Desk

A TypeScript and Native markup workspace with a two-axis project board, a
horizontal reference shelf, nested activity, and keyed reading panels.

```sh
native test -Dplatform=null
native test -Dplatform=null -Dtypescript-view=true
native dev -Dtypescript-view=true
```

Use arrows, PageUp/PageDown, and Home/End to browse. The board and shelf echo
`on-scroll` offsets into their model; reading panels keep independent runtime
positions across refresh and reversal. Presets change one source axis at a time.
Change axis revokes and restores horizontal scrolling, Change edges toggles
rubber-band behavior, and New desk mounts fresh keyed regions.

With the compiled view enabled, scriptc owns offset clamping, keyboard steps,
edge-consumption decisions, and source/retained reconciliation. Native owns
geometry, routing, scroll drivers, wheel physics, and rendering.

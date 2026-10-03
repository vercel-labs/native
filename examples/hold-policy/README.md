# Gesture Lab

A TypeScript and Native markup app exercising presses, press-and-hold, secondary activation, borrowed message payloads, disabled controls and keyed remounting. A hold consumes its release; a control without a hold handler remains an ordinary press.

Run `native dev` for the reference view or `native dev -Dtypescript-view=true` for the compiled view. `native test` exercises complete snapshots, a journaled clock effect and replay; the root regression suite compares both view backends.

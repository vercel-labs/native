# Studio mixer

A TypeScript slider example with model-owned master and preview levels, plus
independent track trims. Drag or click the rails, use arrow keys for 5% steps
(10% with Shift), and use Home/End for the endpoints. Accessibility increment
and decrement actions use the same 5% steps.

Refresh keeps user changes. Studio preset moves the source values; an active
drag retains its thumb position. Lock mixer disables the controls. Keyed tracks
support reversal, hide/restore, and empty/repopulate. New mixer mounts fresh
defaults. The example adjusts levels without playing audio.

```sh
native dev
native test
native test -Dtypescript-view=true
native build -Dtypescript-view=true
```

The compiled view uses scriptc for slider stepping, value clamping, and
source/retained reconciliation. Native keeps pointer geometry and capture,
eligibility, focus, accessibility, change-event coalescing, and rendering.

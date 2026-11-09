# Research Desk

A TypeScript + Native markup app with independent resizable panels. Drag a panel’s right edge to adjust its width. Refresh preserves your adjustments; New desk starts over. Research cards can be reordered, hidden, emptied, or locked.

```sh
native dev
native test -Dplatform=null
native test -Dplatform=null -Dtypescript-view=true
```

`width` seeds a newly mounted panel. Enabled panels retain their width on rebuild, even when Wide defaults changes the authored width. Taller cards raises the drag floor; locked panels use their authored width. Resizing changes the panel itself and leaves child and neighboring frames in place.

With `-Dtypescript-view=true`, scriptc owns drag width clamping and retained-width policy beside the app model. Native owns pointer capture, layout, accessibility, and rendering.

# Pipeline

A TypeScript app with a model-owned stepper and interactive timeline. Next and Previous move through the stages; an index past the final stage marks every step completed. Click a timeline item or focus it and press Enter or Space to select it. Reverse timeline demonstrates keyed identity; Toggle empty removes and restores the history.

```sh
native dev
native test -Dplatform=null
native test -Dplatform=null -Dtypescript-view=true
native build -Dtypescript-view=true
```

The compiled view preview builds the stepper and timeline in TypeScript with scriptc, emitting ordinary native primitive widgets. Rebuild after editing markup. The tests drive the native host through stage changes, pointer routing from title text, keyboard activation, reordering, and replay.

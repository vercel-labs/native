# Habits

A small habit tracker authored in TypeScript and Native markup. Run `native dev` from this directory to add habits, increment streaks, and switch between all and active habits. The 64-habit limit, stable row identities, summary text, and tall titlebar layout are preserved from the original app.

`src/core.ts` owns state and updates, `src/app.native` owns the view, and `app.zon` declares the native window. `native test` runs compiled-app interactions, keyboard navigation, filtering, and replay. The SDK also compares the core and view with the native behavior reference in `tests/ts-core`.

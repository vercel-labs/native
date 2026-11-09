# Accordion policy

A TypeScript account settings app with independent and nested disclosures.
Use Enter/Space or a pointer click to toggle a header. Tab/Shift+Tab visits
body controls after the reveal settles; closed content is absent from
accessibility and cannot receive input.

Open all and Close all update the model. Refresh keeps the current state.
Keyed account sections support reversal, hide/restore, and empty/repopulate;
nested tips keep their expansion when their parent closes.

```sh
native dev
native test
native test -Dtypescript-view=true
native build -Dtypescript-view=true
```

The compiled view uses scriptc for accordion activation and reconciliation
between source and retained expansion. Native owns disclosure animation,
layout, concealed-content eligibility, focus application, and rendering.

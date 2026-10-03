# Workspace Panels

A TypeScript core and Native markup app with a model-declared set of secondary
windows. Every panel shares the same count. Switch the panel set, reverse its
declaration order, or change the user-close action while windows remain open.

`native test -Dplatform=null` exercises the native reference. Add
`-Dtypescript-view=true` to compile both views and portable window reconciliation
with scriptc. Native owns AppKit/Metal operations, retained window storage and
close-message copies. Reconciliation closes stale windows before creating new
ones, preserves existing identities, and retries failed creates on later builds.

`native build -Dautomation=true -Dtypescript-view=true` builds the live app.

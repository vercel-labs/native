# Service Feed Reader

This is a two-layer TypeScript app. `src/core.ts` remains deterministic and
reaches `src/services/feeds.ts` only through `Cmd.request`. The service imports a
vendored parser class and uses ordinary static-tier TypeScript APIs including
`node:fs`, regex, `Map`, `Date`, and JSON. Both layers compile through the exact
scriptc version pinned by the SDK; no JavaScript runtime ships with the app.

Run it from this directory:

```bash
native dev
```

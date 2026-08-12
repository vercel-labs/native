# Record Store

A default TypeScript + Native markup app demonstrating the Tier 2 record
store. It loads a prefix page during `initialModel`, atomically seeds several
records, reads and updates one record, and deletes it without handling a file
path or a SQL statement.

```bash
native test
native run
```

The app declares the `"store"` capability in `app.zon`; builds without that
capability shed the SQLite engine.

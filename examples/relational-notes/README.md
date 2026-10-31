# Relational Notes

The flagship Tier-3 storage example: append-only migrations, SQL prepared by
real SQLite during `native check`, generated typed commands and page decoders,
atomic multi-statement writes, FTS5, and table-invalidated live queries.

```sh
cd examples/relational-notes
../../zig-out/bin/native check
../../zig-out/bin/native dev
```

Edit `src/schema/*.sql` only by adding a new numbered migration. Named queries
live in `src/queries.sql`; the generated `Cmd.q<Name>`, `Sub.q<Name>`, row interfaces, and
`decode<Name>Page` functions exist only for the schema the checker accepted.

Pause and resume live updates, switch folders or search terms, and restart the
query set. Live subscriptions follow the model; cancelling a command does not
remove a declared subscription. `native test` exercises database effects and
replay; the framework suite compares complete snapshots across both backends.

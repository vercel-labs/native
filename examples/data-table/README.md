# data-table

A table of three thousand invoices with sortable columns, a text search, status filters and a
body that only builds the rows on screen. React 19 renders it, Tailwind 4 styles it, and the search
field and Export button come from `@ui-sdk/react`. The footer reports how long the last scroll
render took.

## Build

```console
$ node ../../packages/cli/compiler/cli.ts build . -o build/data-table
$ NATIVE_STEPS='frame 0 | click #filter-overdue | print #result-count | wheel #rows 600 | print #showing' NATIVE_SNAPSHOT=table.png ./build/data-table
```

The rows are generated in the app, so the example carries no data file.

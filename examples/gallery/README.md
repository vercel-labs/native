# gallery

Atlas, a gallery of four thousand generated plates. The four-column grid builds only the rows on
screen, and the search field, favourites filter and two orders work over the whole index. A detail
panel opens beside the grid, and the arrow keys move through the plates. React 19 renders it,
Tailwind 4 styles it, and the search field and buttons come from `@ui-sdk/react`.

## Build

```console
$ node ../../packages/cli/compiler/cli.ts build . -o build/gallery
$ NATIVE_STEPS='frame 0 | print #count | click #sort-popular | wheel #grid 600 | print #showing' NATIVE_SNAPSHOT=gallery.png ./build/gallery
```

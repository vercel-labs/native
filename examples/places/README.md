# places

A shelf of bookmarks in plain HTML, CSS and TypeScript, with no framework. A first run fills an
IndexedDB store from `public/seed.json`; after that every add, edit and delete goes through
IndexedDB. The cards are built with the DOM, the tag bar and search filter the list, and Cmd+F
focuses the search field.

## Build

```console
$ node ../../packages/cli/compiler/cli.ts build . -o build/places
$ NATIVE_STEPS='frame 0 | print #count | click #add | type A small site | click #field-url | type https://example.com | click #save | print #count' NATIVE_SNAPSHOT=places.png ./build/places
```

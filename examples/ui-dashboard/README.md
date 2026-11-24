# ui-dashboard

A launch dashboard: a dark sidebar, live stat cards with sparklines, a revenue chart drawn as
inline SVG, and a projects table with search, status pills, build progress and a dialog that adds a
project. React 19 renders it, Tailwind 4 styles it, and the button comes from `@ui-sdk/react`; the search field and the
project dialog are the page's own controls.

## Build

```console
$ node ../../packages/cli/compiler/cli.ts build . -o build/ui-dashboard
$ NATIVE_STEPS='frame 0 | click #new-project | type acme | click #create-project | frame 16' NATIVE_SNAPSHOT=dashboard.png ./build/ui-dashboard
```

## Styles

`style.css` is the Tailwind 4 build of `input.css`; regenerate it after editing the classes:

```console
$ npm run css
```

The page carries only the utilities the app uses: Tailwind's scanner reads `app.tsx`, `icons.tsx`
and `index.html`, and the generated sheet is what `native build` compiles.

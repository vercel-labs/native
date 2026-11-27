# Shared Geist fonts

Geist Sans and Geist Mono at 400, 500 and 600, as static TrueType files. Link `fonts.css` from an
example and the build copies the faces into the app's bundle next to the executable; nothing is
fetched at runtime.

```html
<link rel="stylesheet" href="../_fonts/fonts.css">
```

```css
body { font-family: "Geist Sans", system-ui, sans-serif; }
code { font-family: "Geist Mono", monospace; }
```

The files are the static faces from the `geist` npm package (SIL OFL 1.1, see `LICENSE.txt`). They are kept as
separate 400/500/600 faces, rather than one variable font, because the SDK's Linux host reads a
font file's tables itself and a variable font registered without an explicit `font-weight` range
defaults to 400. Remote `@font-face` URLs are skipped at build time, so the files stay in the
repository.

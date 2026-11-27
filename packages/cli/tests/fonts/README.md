# Font fixtures

`Geist-Variable-Subset.ttf` is a subset of Geist Variable (wght 100–900), cut to
"Hamburgefonstiv" with `pyftsubset`, keeping its `fvar`/`gvar` tables, so a test can paint two
weights of one variable font without a large binary. `Geist-Variable-H.ttf` is the same font cut
to just "HH", a primary face with no "a" so a family list falls back for the test text. Geist is
Copyright (c) 2023 Vercel, in collaboration with basement.studio, under the SIL Open Font License
1.1 in `OFL.txt`.

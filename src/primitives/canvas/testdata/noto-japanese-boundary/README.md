# Noto Sans JP Japanese outline boundary fixture

`NotoSansJP-japanese-boundary.ttf` is a Modified Version of Noto Sans JP 2.004-H2 containing five kana glyphs and the common-use kanji `鬱`. The fixture exercises Native SDK's registered-font bounds up to 237 points and 26 contours. The complete SIL Open Font License is in `OFL.txt`.

- Source commit: `google/fonts@295d98a7a0c17c68f1341eaeea354e7960ea70d3`
- Source file SHA-256: `c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f`
- Static Regular SHA-256: `946280470c7f8dff9c7256a10c6fb06544c75e83553e906a1a0ad946211de7ed`
- Fixture SHA-256: `8a0c8b2e78eab29b4e26615a93695df8cc5eaae08ef981e517dc207069d9f308`
- Generator: FontTools 4.63.0

```sh
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
curl -fsSL 'https://raw.githubusercontent.com/google/fonts/295d98a7a0c17c68f1341eaeea354e7960ea70d3/ofl/notosansjp/NotoSansJP%5Bwght%5D.ttf' -o "$workdir/NotoSansJP-wght.ttf"
export SOURCE_DATE_EPOCH=1784100876
fonttools varLib.instancer "$workdir/NotoSansJP-wght.ttf" wght=400 --update-name-table --output="$workdir/NotoSansJP-Regular-400.ttf"
pyftsubset "$workdir/NotoSansJP-Regular-400.ttf" '--unicodes=U+3070,U+3071,U+307C,U+307D,U+3091,U+9B31' --output-file=NotoSansJP-japanese-boundary.ttf '--name-IDs=*' --name-legacy '--name-languages=*'
```

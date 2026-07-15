# Noto Sans JP kana boundary fixture

`NotoSansJP-kana-boundary.ttf` is a Modified Version of Noto Sans JP 2.004-H2 containing five kana glyphs that exercise Native SDK's registered-font outline bound. The complete SIL Open Font License is in `OFL.txt`.

- Source commit: `google/fonts@295d98a7a0c17c68f1341eaeea354e7960ea70d3`
- Source file SHA-256: `c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f`
- Static Regular SHA-256: `946280470c7f8dff9c7256a10c6fb06544c75e83553e906a1a0ad946211de7ed`
- Fixture SHA-256: `411ba21d889de26b1a93b37a996734d37f71e63f4c37c7d3092a1c52df64e204`
- Generator: FontTools 4.63.0

```sh
curl -fsSL 'https://raw.githubusercontent.com/google/fonts/295d98a7a0c17c68f1341eaeea354e7960ea70d3/ofl/notosansjp/NotoSansJP%5Bwght%5D.ttf' -o NotoSansJP-wght.ttf
export SOURCE_DATE_EPOCH=1784100876
fonttools varLib.instancer NotoSansJP-wght.ttf wght=400 --update-name-table --output=NotoSansJP-Regular-400.ttf
pyftsubset NotoSansJP-Regular-400.ttf '--unicodes=U+3070,U+3071,U+307C,U+307D,U+3091' --output-file=NotoSansJP-kana-boundary.ttf '--name-IDs=*' --name-legacy '--name-languages=*'
```

# SQLite amalgamation

This directory vendors the SQLite 3.53.4 amalgamation (`sqlite3.c` and
`sqlite3.h`) downloaded from the official SQLite distribution:

- archive: `sqlite-amalgamation-3530400.zip`
- archive SHA3-256: `628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e`
- `sqlite3.c` SHA3-256: `67f423e9ebbbdc473cbc4772c872ee6b89f31fde4ed0279a5c25d5f65c043a16`

SQLite is in the public domain. See <https://sqlite.org/copyright.html>.

Only apps declaring the `store` or `sqlite` capability compile this source
into their artifact.

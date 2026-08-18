# Native SDK schemas

Static JSON Schemas published at `schema.native-sdk.dev`.

- `/app/v1.json` is the stable-major schema URL scaffolded into `app.json`.
- `/app.json` is the short-lived current-version alias.

Create the Vercel project as `native-schema`, set its root directory to
`apps/schema`, leave the framework preset as Other with no build command, and
attach `schema.native-sdk.dev`. `vercel.json` sets the output directory to
`public`. Add a new versioned file only for a breaking manifest contract;
backward-compatible additions update the current major.

The original `https://native-sdk.dev/schemas/app.schema.json` URL remains a
byte-identical compatibility copy owned by the docs deployment.

# Native SDK schemas

Static JSON Schemas published at `schema.native-sdk.dev`.

- `/app/v1.json` is the stable-major schema URL scaffolded into `app.json`.
- `/app.json` is the short-lived current-version alias.

Only those schema URLs are served from this deployment. Every other path
redirects (302) to `https://native-sdk.dev`, so the domain stays a single-
purpose home for the manifest rather than hosting arbitrary content.

Create the Vercel project as `native-schema`, set its root directory to
`apps/schema`, leave the framework preset as Other with no build command, and
attach `schema.native-sdk.dev`. `vercel.json` sets the output directory to
`public`. Add a new versioned file only for a breaking manifest contract;
backward-compatible additions update the current major.

The original `https://native-sdk.dev/schemas/app.schema.json` URL remains a
byte-identical compatibility copy owned by the docs deployment.

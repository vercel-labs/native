# Docs Site Conventions

## MDX Tables

Always use HTML `<table>` syntax in MDX pages, never markdown pipe tables. This ensures consistent styling and avoids MDX parsing edge cases.

```html
<table>
  <thead>
    <tr>
      <th>Column</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>field</code></td>
      <td>What it does</td>
    </tr>
  </tbody>
</table>
```

## Geistdocs

The site uses the public `@vercel/geistdocs` package with Labs branding. Write pages in `content/docs` with a frontmatter `title` and no duplicate H1. Order pages and groups with `content/docs/meta.json` and folder metadata. Keep `/docs/<slug>` URLs and the permanent legacy redirects in `next.config.mjs` stable.

Shared navigation, search, page actions, Markdown routes, MDX rendering, and theme behavior belong to Geistdocs. Local adapters live under `src/components/geistdocs` and `src/lib/geistdocs`. Native component previews and the persisted TypeScript/Zig code tabs remain app-owned. `src/lib/remark-native.ts` exports their static data for Markdown; do not evaluate MDX expressions. Preserve `language:filename` fences and existing heading IDs through `src/lib/remark-docs.ts`.

Reuse an existing dev server. Run checks with `NEXT_DIST_DIR=.next-check pnpm check` so production checks do not share its `.next` directory. The check builds the site, verifies all canonical pages and Markdown siblings over HTTP, checks legacy redirects and discovery, and checks language tabs and the preview WASM. Also run `scripts/gate.sh fast` from the repository root before finishing.

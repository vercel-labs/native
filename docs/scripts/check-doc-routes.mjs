import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath } from "node:url";

const cwd = fileURLToPath(new URL("../", import.meta.url));
const socket = createServer();
await new Promise((resolve) => socket.listen(0, "127.0.0.1", resolve));
const port = socket.address().port;
await new Promise((resolve) => socket.close(resolve));

const server = spawn(process.execPath, [fileURLToPath(import.meta.resolve("next/dist/bin/next")), "start", "--hostname", "127.0.0.1", "--port", String(port)], {
  cwd,
  env: { ...process.env, NODE_ENV: "production" },
  stdio: "inherit",
});
const exited = new Promise((resolve) => server.once("exit", resolve));
const origin = `http://127.0.0.1:${port}`;


try {
  const deadline = Date.now() + 60_000;
  let ready = false;
  while (Date.now() < deadline && server.exitCode === null) {
    try {
      const response = await fetch(`${origin}/robots.txt`, { signal: AbortSignal.timeout(1000) });
      await response.body?.cancel();
      if (response.ok) { ready = true; break; }
    } catch { /* The production server is still starting. */ }
    await sleep(100);
  }
  assert.ok(ready, "Build the docs before running route tests.");
  await checkRoutes(origin);
} finally {
  server.kill("SIGTERM");
  const timeout = setTimeout(() => server.kill("SIGKILL"), 5000);
  await exited;
  clearTimeout(timeout);
}
function proseLines(markdown) {
  const lines = [];
  let fence = null;
  for (const line of markdown.split("\n")) {
    const marker = line.trimStart().match(/^(```|~~~)/)?.[1];
    if (marker) {
      if (fence === marker) fence = null;
      else if (fence === null) fence = marker;
      continue;
    }
    if (fence === null) lines.push(line);
  }
  return lines;
}

function headings(markdown) {
  return proseLines(markdown)
    .map((line) => line.match(/^(#{1,6})\s+(.+?)\s*#*\s*$/))
    .filter(Boolean)
    .map((match) => `${match[1]} ${match[2]}`.replace(/\\([_*`\[\]\\])/g, "$1"));
}

function assertCleanMarkdown(source, markdown, route) {
  // Generic type spellings such as `Sub<Msg>` are legitimate inside inline
  // code and must not be mistaken for unresolved MDX components.
  const prose = proseLines(markdown).join("\n").replace(/`[^`\n]*`/g, "");
  const unresolved = prose.match(/<[A-Z][A-Za-z0-9]*(?:\s|\/?>)/)?.[0];
  if (unresolved) {
    throw new Error(`${route}: unresolved MDX component in Markdown output: ${unresolved}`);
  }
  const unresolvedExpression = prose.match(/\{"[^"\\\r\n]*"\}|\{'[^'\\\r\n]*'\}/)?.[0];
  if (unresolvedExpression) {
    throw new Error(
      `${route}: unresolved MDX string expression in Markdown output: ${unresolvedExpression}`,
    );
  }

  const renderedHeadings = new Set(headings(markdown));
  for (const heading of headings(source)) {
    if (!renderedHeadings.has(heading)) {
      throw new Error(`${route}: Markdown output dropped source heading ${heading}`);
    }
  }

  for (const component of source.matchAll(/<EjectSection\s+components=\{\[([\s\S]*?)\]\}\s*\/>/g)) {
    if (!renderedHeadings.has("## Eject")) {
      throw new Error(`${route}: EjectSection did not render its heading`);
    }
    for (const name of component[1].matchAll(/"([^"]+)"/g)) {
      const command = `native eject component ${name[1]}`;
      if (!markdown.includes(command)) {
        throw new Error(`${route}: EjectSection did not render command ${command}`);
      }
    }
  }
}


function* mdxPages(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) yield* mdxPages(full);
    else if (entry.name.endsWith(".mdx")) yield full;
  }
}

async function checkRoutes(origin) {
  const contentDir = join(cwd, "content/docs");
  const pages = [...mdxPages(contentDir)].map((file) => {
    const slug = relative(contentDir, file).replace(/\\/g, "/").replace(/\.mdx$/, "").replace(/\/index$/, "");
    return { slug, path: `/docs/${slug}`, source: readFileSync(file, "utf8") };
  });
  assert.equal(pages.length, 102, "Keep the full existing documentation corpus");
  const canonicalPaths = new Set(pages.map((page) => page.path));
  const request = (path, options = {}) => fetch(`${origin}${path}`, { redirect: "manual", signal: AbortSignal.timeout(20_000), ...options });
  for (const path of ["/wasm/component-preview.wasm", "/components/button-light.webp", "/Geist-Regular.ttf", "/schemas/app.schema.json"]) {
    const response = await request(path);
    assert.equal(response.status, 200, `Public asset: ${path}`);
    await response.body?.cancel();
  }
  const redirect = async (from, to) => {
    const response = await request(`${from}?ref=route-check`);
    assert.equal(response.status, 308, from);
    const destination = new URL(response.headers.get("location"), origin);
    assert.equal(destination.pathname, to, from);
    assert.equal(destination.search, "?ref=route-check", `Preserve query: ${from}`);
    await response.body?.cancel();
  };
  const renderedPages = new Map();
  const fragmentLinks = [];
  for (const page of pages) {
    const response = await request(page.path, { headers: { Accept: "text/html" } });
    assert.equal(response.status, 200, page.path);
    const html = await response.text();
    renderedPages.set(page.path, html);
    for (const match of html.matchAll(/<a\b[^>]*\bhref="([^"]+)"/g)) {
      const href = match[1].replaceAll("&amp;", "&");
      const target = new URL(href, `${origin}${page.path}`);
      if ((target.origin === origin || target.origin === "https://native-sdk.dev") && target.pathname.startsWith("/docs") && target.hash.length > 1) {
        fragmentLinks.push({ from: page.path, path: target.pathname, id: decodeURIComponent(target.hash.slice(1)) });
      }
    }
    const canonical = `https://native-sdk.dev${page.path}`;
    assert.ok(html.includes(`<link rel="canonical" href="${canonical}"/>`), `${page.path}: canonical`);
    assert.ok(html.includes(`<meta property="og:url" content="${canonical}"/>`), `${page.path}: OG URL`);
    assert.ok(html.includes('data-geistdocs-article="title"') && html.includes('data-geistdocs-article="body"'), `${page.path}: article markers`);
    assert.equal((html.match(/<h1\b/g) ?? []).length, 1, `${page.path}: one title`);
    for (const match of html.matchAll(/<a\b[^>]*\bhref="(\/docs[^"]*)"/g)) {
      const target = match[1].split(/[?#]/, 1)[0];
      assert.ok(canonicalPaths.has(target), `${page.path}: docs link ${target}`);
    }
    for (const heading of headings(page.source)) {
      const label = heading.replace(/^#+ /, "").replace(/`([^`]+)`/g, "$1").replace(/\*\*([^*]+)\*\*/g, "$1");
      const id = label.toLowerCase().replace(/[^\w\s-]/g, "").replace(/\s+/g, "-").replace(/-+/g, "-").trim();
      assert.ok(html.includes(`id="${id}"`), `${page.path}: heading anchor ${id}`);
    }
    const md = await request(`${page.path}.md`);
    assert.equal(md.status, 200, `${page.path}.md`);
    assert.match(md.headers.get("content-type"), /^text\/markdown/);
    assert.equal(md.headers.get("link"), `<${canonical}>; rel="canonical"`);
    const markdown = await md.text();
    assertCleanMarkdown(page.source, markdown, `${page.path}.md`);
    // Keep generated attribute descriptions and both language samples visible to agents.
    if (page.source.includes("<AttrTable")) assert.ok(markdown.includes("Attribute") && markdown.includes("Description"), `${page.path}: attributes`);
    if (page.source.includes("<CodeToggle>")) assert.ok(markdown.includes("```ts") && markdown.includes("```zig"), `${page.path}: both language samples`);
    if (page.source.includes("<Tier")) assert.ok(markdown.includes("First-class") && markdown.includes("Works with caveats") && markdown.includes("Not available"), `${page.path}: platform tiers`);
    await redirect(`/${page.slug}`, page.path);
    await redirect(`/${page.slug}.md`, `${page.path}.md`);
    await redirect(`/md/${page.slug}`, `${page.path}.md`);
  }
  for (const link of fragmentLinks) {
    const html = renderedPages.get(link.path === "/docs" ? "/docs/introduction" : link.path);
    assert.ok(html?.includes(`id="${link.id}"`), `${link.from}: missing fragment ${link.path}#${link.id}`);
  }
  await redirect("/docs", "/docs/introduction");
  await redirect("/docs.md", "/docs/introduction.md");
  await redirect("/philosophy", "/docs/introduction");
  await redirect("/en/docs/introduction", "/docs/introduction");
  const sitemap = await (await request("/sitemap.xml")).text();
  const llms = await (await request("/llms.txt")).text();
  for (const page of pages) {
    assert.ok(sitemap.includes(`https://native-sdk.dev${page.path}</loc>`), `Sitemap: ${page.path}`);
    assert.ok(llms.includes(`https://native-sdk.dev${page.path}`), `llms.txt: ${page.path}`);
  }
  for (const extension of [".md", ".mdx", ""]) {
    const md = await request(`/docs/introduction${extension}`, { headers: { Accept: "text/markdown" } });
    assert.equal(md.status, 200);
    assert.match(md.headers.get("content-type"), /^text\/markdown/);
    await md.body?.cancel();
  }
  for (const headers of [{ "user-agent": "GPTBot" }, { "user-agent": "ClaudeBot" }]) {
    const md = await request("/docs/introduction", { headers });
    assert.match(md.headers.get("content-type"), /^text\/markdown/);
    await md.body?.cancel();
    const html = await request("/docs/introduction", { headers: { ...headers, Accept: "text/html" } });
    assert.match(html.headers.get("content-type"), /^text\/html/);
    await html.body?.cancel();
  }
  for (const path of ["/docs/does-not-exist", "/docs/does-not-exist.md"]) {
    const response = await request(path);
    assert.equal(response.status, 404, path);
    await response.body?.cancel();
  }
  const search = await request("/api/search?query=button");
  assert.equal(search.status, 200);
  const results = await search.json();
  assert.ok(results.some((result) => result.url?.startsWith("/docs/components/button")), "Search includes components");
  for (const path of ["/", "/agents.md", "/sitemap.md", "/og", "/og/components/button"]) {
    const response = await request(path, { headers: { Accept: "text/html" } });
    assert.equal(response.status, 200, path);
    await response.body?.cancel();
  }
  console.log(`docs route check passed: ${pages.length} HTML/Markdown pages, headings, search, discovery, and legacy redirects verified`);
}

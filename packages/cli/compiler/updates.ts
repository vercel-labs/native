// The update check an app opts into: a web app manifest's `update_url`, written into the bundle
// for the runtime to read.
//
// The URL names a JSON document the app fetches:
//
//   { "version": "2.1.0", "url": "https://example.com/Notes-2.1.0.dmg", "notes": "…" }
//
// `version` is the version the update would install, and `url` where the artifact lives. The app
// compares it with the version it was built as and exposes a newer one through
// navigator.serviceWorker (see runtime/updates.ts). Nothing is fetched unless the manifest names
// an update_url, so the check is opt-in.

import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { Diagnostics } from "./diagnostics.ts";
import { findAll, parseHtml } from "./html.ts";
import { PAGE_TABLES_DIR } from "../shared/page-tables.ts";
import type { UpdateConfig } from "../shared/updates.ts";

export type { UpdateConfig } from "../shared/updates.ts";

/** The file's name in the bundle's .native directory. */
export const UPDATE_CONFIG_FILE = "update.json";

/** A version in the `major.minor.patch` form the manifest and the update document use. */
export function updateVersionOf(raw: unknown): string {
  if (typeof raw !== "string") return "1.0.0";
  const m = /^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?/i.exec(raw.trim());
  return m === null ? "1.0.0" : [m[1], m[2] ?? "0", m[3] ?? "0"].join(".");
}

/** A local file the page links, resolved against its directory. */
function localFile(appDir: string, href: string): string | null {
  if (href === "" || /^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith("//")) return null;
  let path = href.split(/[?#]/)[0].replace(/^\/+/, "");
  try {
    path = decodeURIComponent(path);
  } catch {
    // Leave a malformed escape as written.
  }
  const file = resolve(appDir, path);
  return existsSync(file) ? file : null;
}

/** The page's web app manifest, when it links one that parses. */
function pageManifest(htmlPath: string): Record<string, unknown> | null {
  let source = "";
  try {
    source = readFileSync(htmlPath, "utf8");
  } catch {
    return null;
  }
  const appDir = dirname(htmlPath);
  const doc = parseHtml(source, htmlPath, new Diagnostics());
  const link = findAll(doc, (el) => el.tag === "link" &&
    (el.attrs.get("rel") ?? "").toLowerCase().split(/\s+/).includes("manifest"))[0];
  if (link === undefined) return null;
  const file = localFile(appDir, link.attrs.get("href") ?? "");
  if (file === null) return null;
  try {
    const parsed: unknown = JSON.parse(readFileSync(file, "utf8"));
    return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : null;
  } catch {
    return null;
  }
}

/** The bundle's app facts, when a release build wrote them. */
function bundleFacts(resources: string): { updateUrl?: unknown; version?: unknown; name?: unknown } | null {
  const file = join(resources, PAGE_TABLES_DIR, "app.json");
  if (!existsSync(file)) return null;
  try {
    const parsed: unknown = JSON.parse(readFileSync(file, "utf8"));
    return parsed !== null && typeof parsed === "object" ? parsed as Record<string, unknown> : null;
  } catch {
    return null;
  }
}

/**
 * The update config for a built app: `.native/app.json`'s update URL and version when a release
 * build wrote them, otherwise the page's manifest. Null when the app didn't opt in or the URL
 * isn't one the app can fetch.
 */
export function updateConfigOf(resources: string, htmlPath: string): UpdateConfig | null {
  const facts = bundleFacts(resources);
  const manifest = facts === null ? pageManifest(htmlPath) : null;
  const rawUrl = facts !== null && typeof facts.updateUrl === "string" ? facts.updateUrl
    : manifest !== null && typeof manifest.update_url === "string" ? manifest.update_url : "";
  const url = rawUrl.trim();
  if (url === "") return null;
  if (!/^https?:\/\//i.test(url)) {
    console.error(`native: update_url '${rawUrl}' is not an http(s) URL; the app won't check for updates`);
    return null;
  }
  const version = updateVersionOf(facts !== null ? facts.version : manifest?.version);
  const rawName = facts !== null ? facts.name : manifest?.name ?? manifest?.short_name;
  const name = typeof rawName === "string" && rawName.trim() !== "" ? rawName.trim() : "app";
  return { url, version, name };
}

/**
 * Writes the update config beside the page's tables in a built bundle, or removes a stale one
 * when the app stops naming an update URL. The write is atomic: a running app reads either the
 * old document or the new.
 */
export function writeUpdateConfig(resources: string, htmlPath: string): UpdateConfig | null {
  const file = join(resources, PAGE_TABLES_DIR, UPDATE_CONFIG_FILE);
  const config = updateConfigOf(resources, htmlPath);
  if (config === null) {
    rmSync(file, { force: true });
    return null;
  }
  mkdirSync(dirname(file), { recursive: true });
  const tmp = file + ".tmp";
  writeFileSync(tmp, JSON.stringify(config, null, 2) + "\n");
  renameSync(tmp, file);
  return config;
}

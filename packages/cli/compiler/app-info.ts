// What a build knows about the app as a product: its name, identifier, version and icon.
//
// The facts come from the page, the way a browser reads them: the web app manifest the page links,
// its <title> and <link rel="icon"> when there is no manifest, and a package.json beside the page
// as the last resort. A bundled build writes them into the app's bundle, so the macOS Info.plist,
// the Linux .desktop entry and an update check all describe the app the page itself says it is.
// The manifest's `update_url` is read here too; a build without one has no update check.

import { existsSync, readFileSync, statSync } from "node:fs";
import { basename, dirname, extname, join, resolve } from "node:path";
import { Diagnostics } from "./diagnostics.ts";
import { publicDirOf } from "./bundle.ts";
import { findAll, parseHtml, textOf, type HElement } from "./html.ts";

/** An icon the app names, resolved to a file the build can read. */
export interface AppIcon {
  /** The image file on disk. */
  source: string;
  /** The URL the page or manifest named it by. */
  href: string;
  /** Its pixel size, or 0 when the file isn't a PNG the build can measure. */
  width: number;
  height: number;
  /** The media type the page or manifest declared, or one guessed from the extension. */
  type: string;
  /** The purposes the manifest gave it: `any`, `maskable` and `monochrome`. `any` without one. */
  purposes: string[];
  /** Whether the manifest entry stated a purpose at all, which is an author's explicit intent. */
  purposeStated: boolean;
}

/** The app's identity, as a release build writes it into the bundle. */
export interface AppInfo {
  name: string;
  shortName: string;
  /** The bundle identifier: reverse-DNS when the manifest or NATIVE_APP_ID names one. */
  id: string;
  /** The short version string, `major.minor.patch`. */
  version: string;
  /** Every icon the page names, the largest first. */
  icons: AppIcon[];
  /** The largest icon, or null when the page names none. */
  icon: AppIcon | null;
  /** The update manifest URL the app manifest names, or null: no update check. */
  updateUrl: string | null;
  /** The app manifest file the page links, or null. */
  manifest: string | null;
  /** Things wrong with the metadata that didn't stop the build. */
  warnings: string[];
}

/** A manifest member as a non-empty trimmed string. */
function text(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}

/** A package name as a display name: a scoped package's own name, without its scope. */
function unscoped(name: string): string {
  const slash = name.lastIndexOf("/");
  return slash < 0 ? name : name.slice(slash + 1);
}

/** The package.json beside the page, when there is one: the last place an app can name itself. */
function packageManifest(appDir: string): Record<string, unknown> | null {
  const file = join(appDir, "package.json");
  if (!existsSync(file)) return null;
  try {
    const parsed: unknown = JSON.parse(readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
    return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed as Record<string, unknown> : null;
  } catch {
    return null;
  }
}

/** A file name from a display name: lowercase letters, digits and hyphens. */
export function slugOf(name: string): string {
  const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  return slug === "" ? "app" : slug;
}

/** A bundle identifier made from a name, as macOS expects ("letters, digits, hyphen, period"). */
export function defaultBundleIdentifier(name: string): string {
  return "dev.native-sdk." + slugOf(name);
}

/**
 * The version as CFBundleShortVersionString and a .desktop's Version take it: one to three
 * numbers. A manifest's version may carry a leading "v" or a prerelease suffix, which the app's
 * product version leaves out.
 */
export function versionOf(raw: string): string | null {
  const m = /^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?/i.exec(raw.trim());
  if (m === null) return null;
  return [m[1], m[2] ?? "0", m[3] ?? "0"].join(".");
}

/** The PNG's pixel size from its IHDR chunk, or null when the file isn't a PNG. */
function pngSize(file: string): { width: number; height: number } | null {
  let bytes: Buffer;
  try {
    bytes = readFileSync(file);
  } catch {
    return null;
  }
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (bytes.length < 24 || signature.some((b, i) => bytes[i] !== b)) return null;
  if (bytes.toString("ascii", 12, 16) !== "IHDR") return null;
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
}

/** The media type of an icon, from what the page declared or the file's extension. */
function iconType(declared: string | null, href: string): string {
  if (declared !== null && declared.includes("/")) return declared;
  switch (extname(href.split(/[?#]/)[0]).toLowerCase()) {
    case ".png": return "image/png";
    case ".svg": return "image/svg+xml";
    case ".ico": return "image/x-icon";
    case ".jpg":
    case ".jpeg": return "image/jpeg";
    case ".webp": return "image/webp";
    case ".icns": return "image/icns";
    default: return "";
  }
}

/** The largest pixel size a `sizes` attribute names, or 0 for "any" or none. */
function declaredSize(sizes: string | null): number {
  if (sizes === null) return 0;
  let best = 0;
  for (const part of sizes.trim().split(/\s+/)) {
    const m = /^(\d+)x(\d+)$/i.exec(part);
    if (m !== null) best = Math.max(best, Math.min(Number(m[1]), Number(m[2])));
  }
  return best;
}

/** A local URL the page or manifest names, resolved against the app directory (or its public
 *  directory, for a root-relative URL), or null when it names something the build can't read (a
 *  remote or data: URL, or a file that isn't there). */
function localFile(appDir: string, href: string): string | null {
  if (/^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith("//")) return null;
  // A root-relative URL is the app's own root, as the runtime resolves one: the public directory
  // when there is one, else the app directory. The build copies a public file to that root.
  const root = href.startsWith("/") ? publicDirOf(appDir) ?? appDir : appDir;
  let path = href.split(/[?#]/)[0].replace(/^\/+/, "");
  try {
    path = decodeURIComponent(path);
  } catch {
    // A malformed escape is left as written; the file system decides whether it exists.
  }
  const file = resolve(root, path);
  try {
    return existsSync(file) && statSync(file).isFile() ? file : null;
  } catch {
    return null;
  }
}

/** An icon entry from a link or a manifest, when its file is readable. */
function iconOf(appDir: string, href: string, declaredType: string | null, sizes: string | null,
  purpose: string | null, warnings: string[]): AppIcon | null {
  const source = localFile(appDir, href);
  if (source === null) {
    warnings.push(`icon '${href}' is not a file the bundle can hold`);
    return null;
  }
  const measured = pngSize(source);
  const declared = declaredSize(sizes);
  const side = measured === null ? declared : Math.min(measured.width, measured.height);
  const stated = purpose !== null && purpose.trim() !== "";
  const purposes = stated
    ? purpose!.toLowerCase().split(/\s+/).filter((p) => p === "any" || p === "maskable" || p === "monochrome")
    : [];
  return {
    source,
    href,
    width: measured === null ? side : measured.width,
    height: measured === null ? side : measured.height,
    type: iconType(declaredType, href),
    purposes: purposes.length > 0 ? purposes : ["any"],
    // An empty or unknown purpose is no intent at all: the icon takes the default layout.
    purposeStated: purposes.length > 0,
  };
}

/** An icon is usable when the build can measure it: a PNG, for the .icns and the Linux themes. */
function usable(icon: AppIcon): boolean {
  return icon.type === "image/png";
}

/** The icons ordered the way a build wants them: the largest PNG first, then the others. */
function bestFirst(icons: AppIcon[]): AppIcon[] {
  return [...icons].sort((a, b) => {
    const ap = usable(a) ? 1 : 0, bp = usable(b) ? 1 : 0;
    if (ap !== bp) return bp - ap;
    return b.width * b.height - a.width * a.height;
  });
}

/** The rel tokens of a <link>, lowercased. */
function rels(el: HElement): string[] {
  return (el.attrs.get("rel") ?? "").toLowerCase().split(/\s+/).filter((r) => r !== "");
}

/**
 * Reads the app's identity from its page: the web app manifest it links (`name`, `short_name`,
 * `id`, `version`, `icons`, `update_url`) and its <link rel="icon">, with the page's <title> as
 * the name when the manifest has none, then the app's package.json, then its directory name.
 */
export function appInfoOf(htmlPath: string): AppInfo {
  const warnings: string[] = [];
  const appDir = dirname(htmlPath);
  let source = "";
  try {
    source = readFileSync(htmlPath, "utf8");
  } catch {
    // The caller reports a page that can't be read; there is no metadata to read either.
  }
  const doc = parseHtml(source, htmlPath, new Diagnostics());
  const links = findAll(doc, (el) => el.tag === "link");
  const titleEl = findAll(doc, (el) => el.tag === "title")[0];
  const pageTitle = titleEl === undefined ? "" : textOf(titleEl).trim();

  // The manifest the page links, if any. A browser keeps the first one.
  let manifestFile: string | null = null;
  let manifest: Record<string, unknown> | null = null;
  const manifestLink = links.find((el) => rels(el).includes("manifest"));
  const manifestHref = manifestLink === undefined ? "" : manifestLink.attrs.get("href") ?? "";
  if (manifestHref !== "") {
    const file = localFile(appDir, manifestHref);
    if (file === null) {
      warnings.push(`manifest '${manifestHref}' is not a file the build can read`);
    } else {
      manifestFile = file;
      try {
        const parsed: unknown = JSON.parse(readFileSync(file, "utf8"));
        if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) {
          manifest = parsed as Record<string, unknown>;
        } else {
          warnings.push(`manifest '${manifestHref}' is not a JSON object`);
        }
      } catch (err) {
        warnings.push(`manifest '${manifestHref}' is not valid JSON: ${err instanceof Error ? err.message : String(err)}`);
      }
    }
  }

  // The name is the one the page says it is, in the order a browser reads it: the manifest, the
  // <title>, then the app's package.json, and only then the directory the app sits in.
  const pkg = packageManifest(appDir);
  const pkgNameText = text(pkg?.["name"]);
  const pkgName = text(pkg?.["productName"]) ?? (pkgNameText === null ? null : unscoped(pkgNameText));
  const displayName = text(manifest?.["name"]) ?? text(manifest?.["short_name"]) ??
    (pageTitle !== "" ? pageTitle : pkgName ?? basename(resolve(appDir)));
  const manifestShort = text(manifest?.["short_name"]) ?? displayName;
  // A display name is the app's name; a short name is what a menu, a dmg and a .deb have room for.
  const shortName = manifestShort.replace(/[\r\n\t\/\\:]/g, " ").trim() || displayName;

  // The bundle identifier: an explicit one wins, then the manifest's own id when it is already a
  // string macOS accepts, then a name-derived one.
  const envId = text(process.env["NATIVE_APP_ID"]);
  let rawId = envId ?? text(manifest?.["id"]);
  if (rawId !== null && !/^[A-Za-z0-9][A-Za-z0-9.-]*$/.test(rawId)) {
    if (envId === rawId) warnings.push(`NATIVE_APP_ID '${rawId}' is not a bundle identifier (letters, digits, period, hyphen)`);
    rawId = null;
  }
  const id = rawId ?? defaultBundleIdentifier(shortName === "" ? displayName : shortName);

  // The version: NATIVE_APP_VERSION overrides the manifest's, so a release pipeline can version
  // a build without editing the app.
  const envVersion = text(process.env["NATIVE_APP_VERSION"]);
  const rawVersion = envVersion ?? text(manifest?.["version"]);
  let version = "1.0.0";
  if (rawVersion !== null) {
    const parsed = versionOf(rawVersion);
    if (parsed === null) warnings.push(`${envVersion === rawVersion ? "NATIVE_APP_VERSION" : "manifest version"} '${rawVersion}' is not a version number`);
    else version = parsed;
  }

  // Icons: the manifest's, in the browser's order, then the page's <link rel="icon"> as a
  // fallback. A page may name both; the manifest's set is the app's, so the link only fills in
  // when the manifest has none the build can read.
  const icons: AppIcon[] = [];
  const manifestIcons = manifest?.["icons"];
  if (Array.isArray(manifestIcons)) {
    for (const entry of manifestIcons) {
      if (entry === null || typeof entry !== "object") continue;
      const record = entry as Record<string, unknown>;
      const href = text(record["src"]);
      if (href === null) continue;
      const icon = iconOf(appDir, href, text(record["type"]), text(record["sizes"]), text(record["purpose"]), warnings);
      if (icon !== null) icons.push(icon);
    }
  }
  if (!icons.some(usable)) {
    for (const el of links) {
      const r = rels(el);
      if (!r.includes("icon")) continue;
      const href = el.attrs.get("href") ?? "";
      if (href === "") continue;
      const icon = iconOf(appDir, href, el.attrs.get("type") ?? null, el.attrs.get("sizes") ?? null, null, warnings);
      if (icon !== null) icons.push(icon);
    }
  }
  const ordered = bestFirst(icons);

  // The update check is opt-in: only an absolute http(s) URL in the manifest turns it on.
  const updateUrl = text(manifest?.["update_url"]);
  if (updateUrl !== null && !/^https?:\/\//i.test(updateUrl)) {
    warnings.push(`update_url '${updateUrl}' is not an http(s) URL; the app won't check for updates`);
  }

  return {
    name: displayName,
    shortName: shortName === "" ? displayName : shortName,
    id,
    version,
    icons: ordered,
    icon: ordered.find(usable) ?? null,
    updateUrl: updateUrl !== null && /^https?:\/\//i.test(updateUrl) ? updateUrl : null,
    manifest: manifestFile,
    warnings,
  };
}

/** The app facts a bundle carries, in `.native/app.json`, for the runtime and the installers. */
export interface BundledAppInfo {
  name: string;
  shortName: string;
  id: string;
  version: string;
  updateUrl: string | null;
  /** The icon's path inside the bundle's resources, or null. */
  icon: string | null;
  /** The platform-ready icon (inset and on macOS masked) beside the source, or null. */
  iconReady: string | null;
}

/** The bundle's app.json for an app, with the icon at the path a bundle gives it. */
export function bundledInfo(info: AppInfo, iconReady = false): BundledAppInfo {
  return {
    name: info.name,
    shortName: info.shortName,
    id: info.id,
    version: info.version,
    updateUrl: info.updateUrl,
    icon: info.icon === null ? null : ".native/icon.png",
    iconReady: iconReady && info.icon !== null ? ".native/icon-ready.png" : null,
  };
}

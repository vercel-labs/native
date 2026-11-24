// Linux distribution: a .deb a package manager installs and an AppImage someone runs from a
// download folder, both carrying a .desktop entry and the app's icon.
//
// The app's name, version and icon come from the bundle's `.native/app.json` when the build wrote
// one, and otherwise from the page's web app manifest, its <title> or its <link rel="icon">, so
// packaging works with a plain build too. The .deb is written directly (ar + tar.gz); the
// AppImage is assembled from an AppDir by appimagetool, which must be on PATH or named by
// APPIMAGETOOL.

import { chmodSync, copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, relative } from "node:path";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { deflateSync, gzipSync } from "node:zlib";
import { Diagnostics } from "./diagnostics.ts";
import { findAll, parseHtml, textOf, type HElement } from "./html.ts";
import type { BuildResult } from "./build.ts";

/** The two artifacts a Linux release writes. */
export interface LinuxRelease {
  deb: string;
  appimage: string;
  arch: string;
}

/** What packaging knows about the app. */
export interface LinuxApp {
  /** The name a desktop shows. */
  name: string;
  /** The package and executable name: lowercase letters, digits, '+', '-', '.'. */
  pkg: string;
  /** The desktop entry's Icon name. */
  iconName: string;
  /** major.minor.patch. */
  version: string;
  /** The icon file, when the app has a PNG of its own. */
  icon: string | null;
  iconWidth: number;
  iconHeight: number;
}

const STOCK_ICON_SIZES = new Set([16, 24, 32, 48, 64, 128, 256, 512]);

/** A Debian package name from a file or display name. */
export function packageNameOf(name: string): string {
  const pkg = name.toLowerCase().replace(/[^a-z0-9+.-]+/g, "-").replace(/^[^a-z0-9]+|-+$/g, "");
  return pkg === "" ? "app" : pkg;
}

/** A version Debian and the desktop entry accept: one to three numbers. */
export function packageVersionOf(raw: string): string {
  const m = /^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?/i.exec(raw.trim());
  return m === null ? "1.0.0" : [m[1], m[2] ?? "0", m[3] ?? "0"].join(".");
}

/** The Debian architecture of this build. */
export function debArch(arch: string = process.arch): string {
  return arch === "x64" ? "amd64" : arch === "arm64" ? "arm64" : arch === "ia32" ? "i386" : arch === "arm" ? "armhf" : "amd64";
}

/** The architecture name an AppImage uses. */
export function appImageArch(arch: string = process.arch): string {
  return arch === "x64" ? "x86_64" : arch === "arm64" ? "aarch64" : arch === "ia32" ? "i686" : arch === "arm" ? "armhf" : "x86_64";
}

/** The PNG's pixel size from its IHDR, or null when the file isn't a PNG. */
function pngSize(file: string): { width: number; height: number } | null {
  try {
    const b = readFileSync(file);
    const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    if (b.length < 24 || signature.some((v, i) => b[i] !== v) || b.toString("ascii", 12, 16) !== "IHDR") return null;
    return { width: b.readUInt32BE(16), height: b.readUInt32BE(20) };
  } catch {
    return null;
  }
}

/** The rel tokens of a <link>, lowercased. */
function rels(el: HElement): string[] {
  return (el.attrs.get("rel") ?? "").toLowerCase().split(/\s+/).filter((r) => r !== "");
}

/** A local URL the page names, resolved against its directory, or null for anything else. */
function localFile(appDir: string, href: string): string | null {
  if (href === "" || /^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith("//")) return null;
  let path = href.split(/[?#]/)[0].replace(/^\/+/, "");
  try {
    path = decodeURIComponent(path);
  } catch {
    // Leave a malformed escape as written.
  }
  const file = join(appDir, path);
  return existsSync(file) && statSync(file).isFile() ? file : null;
}

/** The largest PNG icon the page's manifest or <link rel="icon"> names. */
function pageIcon(htmlPath: string, appDir: string): string | null {
  let source = "";
  try {
    source = readFileSync(htmlPath, "utf8");
  } catch {
    return null;
  }
  const doc = parseHtml(source, htmlPath, new Diagnostics());
  const links = findAll(doc, (el) => el.tag === "link");
  const candidates: string[] = [];
  const manifestLink = links.find((el) => rels(el).includes("manifest"));
  const manifestFile = manifestLink === undefined ? null : localFile(appDir, manifestLink.attrs.get("href") ?? "");
  if (manifestFile !== null) {
    try {
      const manifest: unknown = JSON.parse(readFileSync(manifestFile, "utf8"));
      const icons = manifest !== null && typeof manifest === "object" ? (manifest as { icons?: unknown }).icons : undefined;
      if (Array.isArray(icons)) {
        for (const entry of icons) {
          if (entry === null || typeof entry !== "object") continue;
          const src = (entry as { src?: unknown }).src;
          if (typeof src === "string") {
            const file = localFile(appDir, src);
            if (file !== null) candidates.push(file);
          }
        }
      }
    } catch {
      // A manifest that doesn't parse leaves the page's own icon to answer.
    }
  }
  if (candidates.length === 0) {
    for (const el of links) {
      if (!rels(el).includes("icon")) continue;
      const file = localFile(appDir, el.attrs.get("href") ?? "");
      if (file !== null) candidates.push(file);
    }
  }
  const pngs = candidates.map((file) => ({ file, size: pngSize(file) })).filter((c) => c.size !== null);
  pngs.sort((a, b) => (b.size!.width * b.size!.height) - (a.size!.width * a.size!.height));
  return pngs.length === 0 ? null : pngs[0].file;
}

/** The app's packaging facts: the bundle's app.json when it has one, the page otherwise. */
export function linuxAppOf(resources: string, htmlPath: string, executable: string): LinuxApp {
  const fallback = packageNameOf(basename(executable));
  let name = basename(executable);
  let version = "1.0.0";
  let icon: string | null = null;
  const appJson = join(resources, ".native", "app.json");
  if (existsSync(appJson)) {
    try {
      const facts = JSON.parse(readFileSync(appJson, "utf8")) as { name?: unknown; shortName?: unknown; version?: unknown; icon?: unknown };
      if (typeof facts.name === "string" && facts.name.trim() !== "") name = facts.name.trim();
      if (typeof facts.version === "string") version = packageVersionOf(facts.version);
      if (typeof facts.icon === "string" && facts.icon !== "") {
        const file = join(resources, ...facts.icon.split("/"));
        if (existsSync(file)) icon = file;
      }
    } catch {
      // A bundle without readable facts falls back to the page.
    }
  } else {
    icon = pageIcon(htmlPath, dirname(htmlPath));
    try {
      const src = readFileSync(htmlPath, "utf8");
      const title = /<title[^>]*>([^<]*)<\/title>/i.exec(src);
      if (title !== null && title[1].trim() !== "") name = title[1].trim();
      const manifestLink = /<link[^>]+rel\s*=\s*["']?[^"'>]*manifest[^"'>]*["']?[^>]*>/i.exec(src);
      if (manifestLink !== null) {
        const href = /href\s*=\s*["']([^"']+)["']/i.exec(manifestLink[0]);
        const file = href === null ? null : localFile(dirname(htmlPath), href[1]);
        if (file !== null) {
          const manifest = JSON.parse(readFileSync(file, "utf8")) as { name?: unknown; short_name?: unknown; version?: unknown };
          if (typeof manifest.name === "string" && manifest.name !== "") name = manifest.name;
          else if (typeof manifest.short_name === "string" && manifest.short_name !== "") name = manifest.short_name;
          if (typeof manifest.version === "string") version = packageVersionOf(manifest.version);
        }
      }
    } catch {
      // The title and manifest are conveniences; the executable's name always works.
    }
  }
  const pkg = packageNameOf(name === basename(executable) ? fallback : name);
  const size = icon === null ? null : pngSize(icon);
  return {
    name,
    pkg,
    iconName: pkg,
    version,
    icon,
    iconWidth: size?.width ?? 0,
    iconHeight: size?.height ?? 0,
  };
}

/** The .desktop entry a desktop or a launcher reads. */
export function desktopEntry(app: LinuxApp): string {
  return [
    "[Desktop Entry]",
    "Type=Application",
    `Name=${app.name}`,
    `Comment=${app.name}, built with native`,
    `Exec=${app.pkg}`,
    `Icon=${app.iconName}`,
    "Terminal=false",
    "Categories=Utility;",
    `StartupWMClass=${app.name}`,
    `X-AppImage-Version=${app.version}`,
    "",
  ].join("\n");
}

/** A deterministic solid-colour PNG, for an app that has no icon of its own. */
export function defaultIcon(size = 256): Buffer {
  const hash = createHash("sha1").update("native").digest();
  const r = 64 + (hash[0] % 128), g = 64 + (hash[1] % 128), b = 64 + (hash[2] % 128);
  const stride = size * 4 + 1;
  const raw = Buffer.alloc(stride * size);
  const radius = size / 2;
  for (let y = 0; y < size; y++) {
    raw[y * stride] = 0;
    for (let x = 0; x < size; x++) {
      const o = y * stride + 1 + x * 4;
      const dx = x + 0.5 - radius, dy = y + 0.5 - radius;
      const inside = dx * dx + dy * dy <= (radius - 4) * (radius - 4);
      raw[o] = r;
      raw[o + 1] = g;
      raw[o + 2] = b;
      raw[o + 3] = inside ? 255 : 0;
    }
  }
  return encodePng(size, size, raw);
}

/** A minimal PNG encoder: 8-bit RGBA, one filter-0 scanline per row. */
function encodePng(width: number, height: number, raw: Buffer): Buffer {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  const crc = (buf: Buffer): number => {
    let c = -1;
    for (const byte of buf) c = table[(c ^ byte) & 0xff] ^ (c >>> 8);
    return (c ^ -1) >>> 0;
  };
  const chunk = (type: string, data: Buffer): Buffer => {
    const head = Buffer.alloc(8);
    head.writeUInt32BE(data.length, 0);
    head.write(type, 4, "ascii");
    const tail = Buffer.alloc(4);
    tail.writeUInt32BE(crc(Buffer.concat([head.subarray(4), data])), 0);
    return Buffer.concat([head, data, tail]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

/** One file in a tar archive. */
interface TarEntry { path: string; type: "file" | "dir" | "symlink"; mode: number; data?: Buffer; link?: string }

/** A ustar header's octal field. */
function octal(value: number, width: number): string {
  return value.toString(8).padStart(width - 1, "0") + "\0";
}

/** Splits a path into the ustar name and prefix fields. */
function splitTarPath(path: string): { name: string; prefix: string } {
  if (Buffer.byteLength(path) <= 100) return { name: path, prefix: "" };
  const bytes = Buffer.from(path);
  for (let i = bytes.length - 101; i > 0; i--) {
    if (bytes[i] !== 0x2f || i > 155) continue;
    return { name: bytes.toString("utf8", i + 1), prefix: bytes.toString("utf8", 0, i) };
  }
  throw new Error(`native: '${path}' is too long for a .deb archive`);
}

/** A tar archive of entries, gzipped: the shape a .deb's control and data members take. */
export function tarGz(entries: readonly TarEntry[]): Buffer {
  const blocks: Buffer[] = [];
  for (const entry of entries) {
    const { name, prefix } = splitTarPath(entry.path);
    const header = Buffer.alloc(512);
    header.write(name, 0, "utf8");
    header.write(octal(entry.mode, 8), 100, "ascii");
    header.write(octal(0, 8), 108, "ascii");
    header.write(octal(0, 8), 116, "ascii");
    header.write(octal(entry.data === undefined ? 0 : entry.data.length, 12), 124, "ascii");
    header.write(octal(0, 12), 136, "ascii");
    header.fill(0x20, 148, 156);
    header.write(entry.type === "dir" ? "5" : entry.type === "symlink" ? "2" : "0", 156, "ascii");
    if (entry.link !== undefined) header.write(entry.link, 157, "utf8");
    header.write("ustar\0" + "00", 257, "ascii");
    header.write(prefix, 345, "utf8");
    let sum = 0;
    for (const byte of header) sum += byte;
    header.write(sum.toString(8).padStart(6, "0") + "\0 ", 148, "ascii");
    blocks.push(header);
    if (entry.data !== undefined) {
      blocks.push(entry.data);
      const pad = (512 - (entry.data.length % 512)) % 512;
      if (pad > 0) blocks.push(Buffer.alloc(pad));
    }
  }
  blocks.push(Buffer.alloc(1024));
  return gzipSync(Buffer.concat(blocks), { level: 9 });
}

/** One member of an ar archive. */
interface ArMember { name: string; data: Buffer }

/** An ar archive, the container a .deb is. */
export function arArchive(members: readonly ArMember[]): Buffer {
  const parts: Buffer[] = [Buffer.from("!<arch>\n", "ascii")];
  for (const member of members) {
    const header = Buffer.alloc(60, 0x20);
    header.write(member.name, 0, "ascii");
    header.write("0", 16, "ascii");
    header.write("0", 28, "ascii");
    header.write("0", 34, "ascii");
    header.write("100644", 40, "ascii");
    header.write(String(member.data.length), 48, "ascii");
    header.write("`\n", 58, "ascii");
    parts.push(header, member.data);
    if (member.data.length % 2 === 1) parts.push(Buffer.from("\n", "ascii"));
  }
  return Buffer.concat(parts);
}

/** The files under a staged directory as tar entries, with a "./" path prefix. */
function treeEntries(root: string): TarEntry[] {
  const entries: TarEntry[] = [];
  const walk = (dir: string): void => {
    for (const name of readdirSync(dir).sort()) {
      const path = join(dir, name);
      const rel = "./" + relative(root, path).split("\\").join("/");
      const st = lstatSync(path);
      if (st.isDirectory()) {
        entries.push({ path: rel, type: "dir", mode: 0o755 });
        walk(path);
      } else if (st.isSymbolicLink()) {
        entries.push({ path: rel, type: "symlink", mode: 0o777, link: readlinkSync(path) });
      } else {
        entries.push({ path: rel, type: "file", mode: st.mode & 0o777, data: readFileSync(path) });
      }
    }
  };
  walk(root);
  return entries;
}

/** Copies the app into `dir` as usr/bin/<pkg> and its resources, plus the desktop entry and
 *  icons a desktop reads. The AppImage's AppDir and the .deb's data tree share this shape. */
function stageApp(dir: string, result: BuildResult, app: LinuxApp): void {
  const bin = join(dir, "usr", "bin");
  mkdirSync(bin, { recursive: true });
  copyFileSync(result.output, join(bin, app.pkg));
  // The executable finds its files beside itself: <executable>.resources.
  cpTree(result.resources, join(bin, app.pkg + ".resources"));
  const desktop = desktopEntry(app);
  const apps = join(dir, "usr", "share", "applications");
  mkdirSync(apps, { recursive: true });
  writeFileSync(join(apps, app.pkg + ".desktop"), desktop);
  writeIcon(dir, app);
}

/** Copies a directory tree, creating the destination. */
function cpTree(source: string, dest: string): void {
  mkdirSync(dest, { recursive: true });
  for (const name of readdirSync(source)) {
    const from = join(source, name);
    const to = join(dest, name);
    const st = lstatSync(from);
    if (st.isDirectory()) cpTree(from, to);
    else if (st.isSymbolicLink()) symlinkSync(readlinkSync(from), to);
    else copyFileSync(from, to);
  }
}

/** Writes the icon into the hicolor theme (at its own size) and pixmaps. */
function writeIcon(root: string, app: LinuxApp): void {
  const icon = app.icon === null ? defaultIcon() : readFileSync(app.icon);
  const side = app.icon === null ? 256 : Math.min(app.iconWidth, app.iconHeight);
  if (STOCK_ICON_SIZES.has(side)) {
    const themed = join(root, "usr", "share", "icons", "hicolor", `${side}x${side}`, "apps");
    mkdirSync(themed, { recursive: true });
    writeFileSync(join(themed, app.pkg + ".png"), icon);
  }
  const pixmaps = join(root, "usr", "share", "pixmaps");
  mkdirSync(pixmaps, { recursive: true });
  writeFileSync(join(pixmaps, app.pkg + ".png"), icon);
}

/** Writes the .deb: debian-binary, control.tar.gz and data.tar.gz in an ar archive. */
export function writeDeb(file: string, result: BuildResult, app: LinuxApp, arch: string = process.arch): void {
  const work = mkdtempSync(join(tmpdir(), "native-deb-"));
  try {
    const data = join(work, "data");
    const opt = join(data, "opt", app.pkg);
    mkdirSync(opt, { recursive: true });
    copyFileSync(result.output, join(opt, app.pkg));
    cpTree(result.resources, join(opt, app.pkg + ".resources"));
    const bin = join(data, "usr", "bin");
    mkdirSync(bin, { recursive: true });
    symlinkSync(`/opt/${app.pkg}/${app.pkg}`, join(bin, app.pkg));
    const apps = join(data, "usr", "share", "applications");
    mkdirSync(apps, { recursive: true });
    writeFileSync(join(apps, app.pkg + ".desktop"), desktopEntry(app));
    writeIcon(data, app);
    let bytes = 0;
    const countBytes = (dir: string): void => {
      for (const name of readdirSync(dir)) {
        const path = join(dir, name);
        const st = lstatSync(path);
        if (st.isDirectory()) countBytes(path);
        else if (st.isFile()) bytes += st.size;
      }
    };
    countBytes(data);
    const control = [
      `Package: ${app.pkg}`,
      `Version: ${app.version}`,
      "Section: utils",
      "Priority: optional",
      `Architecture: ${debArch(arch)}`,
      `Installed-Size: ${Math.ceil(bytes / 1024)}`,
      "Maintainer: Native SDK <noreply@example.com>",
      `Description: ${app.name}`,
      " A native app compiled from HTML, CSS and TypeScript by native.",
      "",
    ].join("\n");
    const controlTar = tarGz([
      { path: "./control", type: "file", mode: 0o644, data: Buffer.from(control, "utf8") },
    ]);
    const dataTar = tarGz(treeEntries(data));
    const deb = arArchive([
      { name: "debian-binary", data: Buffer.from("2.0\n", "ascii") },
      { name: "control.tar.gz", data: controlTar },
      { name: "data.tar.gz", data: dataTar },
    ]);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, deb);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

/** The appimagetool to run, from APPIMAGETOOL or PATH, or null when it isn't installed. */
export function appImageTool(): string | null {
  const named = process.env["APPIMAGETOOL"];
  if (named !== undefined && named !== "") return named;
  const r = spawnSync("appimagetool", ["--version"], { encoding: "utf8" });
  return r.error === undefined && r.status === 0 ? "appimagetool" : null;
}

/** Writes the AppImage from an AppDir with appimagetool. */
export function writeAppImage(file: string, result: BuildResult, app: LinuxApp, arch: string = process.arch): void {
  const tool = appImageTool();
  if (tool === null) {
    throw new Error("native: AppImage packaging needs appimagetool on PATH, or APPIMAGETOOL naming it");
  }
  const work = mkdtempSync(join(tmpdir(), "native-appimage-"));
  try {
    const appDir = join(work, "AppDir");
    stageApp(appDir, result, app);
    // appimagetool reads the desktop file and icon at the AppDir's root.
    copyFileSync(join(appDir, "usr", "share", "applications", app.pkg + ".desktop"), join(appDir, app.pkg + ".desktop"));
    const icon = app.icon === null ? join(appDir, "usr", "share", "pixmaps", app.pkg + ".png") : app.icon;
    copyFileSync(icon, join(appDir, app.pkg + ".png"));
    symlinkSync(app.pkg + ".png", join(appDir, ".DirIcon"));
    const run = join(appDir, "AppRun");
    writeFileSync(run, [
      "#!/bin/sh",
      'here=$(dirname "$(readlink -f "$0")")',
      `exec "$here/usr/bin/${app.pkg}" "$@"`,
      "",
    ].join("\n"));
    chmodSync(run, 0o755);
    const r = spawnSync(tool, ["--no-appstream", appDir, file], {
      encoding: "utf8",
      env: { ...process.env, APPIMAGE_EXTRACT_AND_RUN: "1", ARCH: appImageArch(arch), VERSION: app.version },
    });
    if (r.error !== undefined) throw new Error(`native: AppImage packaging: ${tool} couldn't run (${r.error.message})`);
    if (r.status !== 0) throw new Error(`native: appimagetool failed\n${(r.stderr || r.stdout).trim()}`);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

/** Packages a built Linux app: a .deb and an AppImage beside the executable. */
export function packageLinux(htmlPath: string, result: BuildResult): LinuxRelease | null {
  if (result.resources === "") return null;
  const app = linuxAppOf(result.resources, htmlPath, result.output);
  const dir = dirname(result.output);
  const arch = process.arch;
  const deb = join(dir, `${app.pkg}_${app.version}_${debArch(arch)}.deb`);
  const appimage = join(dir, `${app.pkg}-${app.version}-${appImageArch(arch)}.AppImage`);
  writeDeb(deb, result, app, arch);
  console.error(`native: ${relative(process.cwd(), deb)} (${(statSync(deb).size / 1024 / 1024).toFixed(1)} MB)`);
  writeAppImage(appimage, result, app, arch);
  console.error(`native: ${relative(process.cwd(), appimage)} (${(statSync(appimage).size / 1024 / 1024).toFixed(1)} MB)`);
  return { deb, appimage, arch: debArch(arch) };
}

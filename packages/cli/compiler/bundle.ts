// The files a built app reads at runtime, copied into its bundle.
//
// A built app is self-contained: its images, @font-face files, the files its scripts fetch and
// the style sheets it links are copied next to the executable (inside the .app's Resources on
// macOS) and every path the build writes into a table is relative to that directory. Assets keep
// the place they had in the app, so a page-relative URL still names the same file at runtime: a
// script that sets an Image's src, or fetches a URL the build couldn't see, resolves it against
// the bundle just as it resolved against the app's directory before.

import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, statSync } from "node:fs";
import { basename, dirname, extname, isAbsolute, join, relative, sep } from "node:path";
import { createHash } from "node:crypto";

/** One file the bundle holds: where it comes from and where it goes, relative to the bundle. */
export interface BundleFile {
  source: string;
  /** The file's path inside the bundle, with "/" separators. */
  dest: string;
}

/** A hash of a file's bytes, for naming a copy of a file that has no place in the app dir. */
function contentHash(file: string): string {
  return createHash("sha1").update(readFileSync(file)).digest("hex");
}

/** The directory a build serves at the app's root: `public` beside the page, when there is one.
 *  Its files are copied into the bundle as they are, so a URL the build never saw still resolves
 *  (see docs/cli.md). */
export function publicDirOf(appDir: string): string | null {
  const dir = join(appDir, "public");
  try {
    return statSync(dir).isDirectory() ? dir : null;
  } catch {
    return null;
  }
}

/** Whether `file` is `dir` itself or a path below it. */
function under(dir: string, file: string): boolean {
  const rel = relative(dir, file);
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

/**
 * Collects the files a build refers to, giving each the path it will have in the bundle. The
 * same source is only ever added once, and two different sources never share a path: a file
 * outside the app directory is stored under a name made from its content, and a clash between
 * two names (which only a case-insensitive filesystem would have) takes a numbered suffix.
 *
 * A `public` directory beside the page is the app's site root, as it is for the web's build
 * tools: its files keep the paths they have under it, and a runtime URL under the root names
 * one of them.
 */
export class AssetBundle {
  private readonly appDir: string;
  private readonly publicDir: string | null;
  private readonly bySource = new Map<string, string>();
  private readonly used = new Set<string>();
  /** The files to copy, in the order they were first referred to. */
  readonly files: BundleFile[] = [];

  constructor(appDir: string, publicDir: string | null = null) {
    this.appDir = appDir;
    this.publicDir = publicDir;
  }

  /**
   * The path a referenced file has in the bundle, adding it if this is its first reference. A
   * `preferred` name is used when the build knows a good one (a data: image decoded to a file
   * of its own); otherwise the file keeps the path it has relative to the app, and one from
   * outside the app is named by its content.
   */
  add(source: string, preferred?: string): string {
    const hit = this.bySource.get(source);
    if (hit !== undefined) return hit;
    const dest = this.unique(preferred ?? this.nameFor(source));
    this.bySource.set(source, dest);
    this.used.add(dest.toLowerCase());
    this.files.push({ source, dest });
    return dest;
  }

  /** Notes a file the build reads but the runtime doesn't (a linked style sheet). */
  copy(source: string): string {
    return this.add(source);
  }

  /**
   * Adds every file in the public directory as it is, at the path it has under that directory.
   * The directory is copied into the build whole, so a URL the build never saw still names a
   * file at runtime.
   */
  addPublicDir(): void {
    if (this.publicDir === null) return;
    const visited = new Set<string>();
    const walk = (at: string): void => {
      // A directory symlink is followed, and a loop through one stops where it closes.
      const real = realpathSync(at);
      if (visited.has(real)) return;
      visited.add(real);
      const entries = readdirSync(at, { withFileTypes: true })
        .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
      for (const entry of entries) {
        const source = join(at, entry.name);
        // A directory symlink is followed, so ask the link's target what it is; a plain entry
        // answers for itself. The two paths keep each stat call on one concrete type.
        if (entry.isSymbolicLink()) {
          const target = statSync(source, { throwIfNoEntry: false });
          if (target === undefined) continue;
          if (target.isDirectory()) walk(source);
          else if (target.isFile()) this.add(source);
        } else if (entry.isDirectory()) walk(source);
        else if (entry.isFile()) this.add(source);
      }
    };
    walk(this.publicDir);
  }

  /** The file's path in the bundle, whether or not anything has referred to it yet. */
  private nameFor(source: string): string {
    // A public file is named from the public directory: that directory is the site root, and a
    // URL never spells it out.
    const root = this.publicDir !== null && under(this.publicDir, source) ? this.publicDir : this.appDir;
    const rel = relative(root, source);
    if (rel !== "" && !rel.startsWith("..") && !isAbsolute(rel)) return rel.split(sep).join("/");
    // A file the app reaches outside its directories (a data: image, a sheet's @import from
    // elsewhere): a content name is stable across builds and machines.
    const ext = extname(source);
    const stem = basename(source, ext);
    return `_external/${contentHash(source).slice(0, 12)}-${stem}${ext}`;
  }

  /** The name, with a number appended before the extension until it is free. */
  private unique(name: string): string {
    let candidate = name;
    const ext = extname(name);
    const stem = name.slice(0, name.length - ext.length);
    for (let n = 2; this.used.has(candidate.toLowerCase()); n++) candidate = `${stem}-${n}${ext}`;
    return candidate;
  }
}

/** What copying a bundle wrote, for the build's summary line. */
export interface BundleCopy {
  count: number;
  bytes: number;
}

/**
 * Writes the bundle's files under `dir`, replacing what an earlier build left there. The
 * directory is the build's own (the .app's Resources, or the one beside the executable), so
 * anything stale in it goes; a file that can't be read is a build error naming it.
 */
export function copyBundle(files: readonly BundleFile[], dir: string): BundleCopy {
  rmSync(dir, { recursive: true, force: true });
  let bytes = 0;
  for (const file of files) {
    if (!existsSync(file.source)) {
      throw new Error(`native: asset '${relative(process.cwd(), file.source) || file.source}' is missing`);
    }
    const dest = join(dir, ...file.dest.split("/"));
    mkdirSync(dirname(dest), { recursive: true });
    copyFileSync(file.source, dest);
    bytes += statSync(dest).size;
  }
  return { count: files.length, bytes };
}

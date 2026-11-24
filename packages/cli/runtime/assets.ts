// Where a built app's own files live at runtime.
//
// A release build copies everything the app reads (images, @font-face files, files a script
// fetches, its style sheets) into a bundle beside the executable and records the paths in its
// tables relative to that bundle. The host reports the bundle's directory at startup — the .app's
// Resources on macOS, the directory beside the executable elsewhere — and every path a host call
// receives goes through here. A dev build keeps the files where the source has them, and a path
// that is already absolute passes through untouched.

let root = "";

/** Records the directory the app's files were copied into; "" for a build that isn't bundled. */
export function setAssetRoot(dir: string): void {
  root = dir === "" ? "" : dir.replace(/\/+$/, "");
}

/** The directory the app's files were copied into, or "" for a build that isn't bundled. */
export function assetRoot(): string {
  return root;
}

/** The place on disk a path the build wrote names: the bundle's copy of a relative path, or the
 *  absolute path itself (a dev build's, or one a script built from a directory). */
export function assetPath(path: string): string {
  if (path === "" || path.startsWith("/") || root === "") return path;
  return root + "/" + path;
}

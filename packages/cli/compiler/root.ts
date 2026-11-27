// Where native's own files are: the runtime/, shared/ and host/ sources every app build compiles,
// and the node_modules that holds scriptc and @scriptc/types.
//
// Run by Node from a checkout, that is the directory above compiler/. The native executable
// (scripts/build-native.ts) has no source tree of its own: its import.meta.url is the file it was
// compiled from, on the machine that compiled it. The build marks it with NATIVE_SDK_BINARY, and
// it finds the sources from NATIVE_SDK_ROOT, which the npm launcher sets to the package that
// ships them, or else from the first directory at or above the executable that holds them (a
// build in dist/ of a checkout, or an unpacked archive with the executable in bin/).

import { existsSync, realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** True in the native executable, false when Node runs the TypeScript sources. */
export const NATIVE_BINARY = process.env.NATIVE_SDK_BINARY === "1";

function holdsSources(dir: string): boolean {
  return existsSync(join(dir, "runtime", "app.ts")) && existsSync(join(dir, "host"));
}

function binaryRoot(): string {
  const named = process.env.NATIVE_SDK_ROOT;
  if (named !== undefined && named !== "") return resolve(named);
  let exe = process.execPath;
  try {
    exe = realpathSync(exe);
  } catch {
    // the path it was started from
  }
  for (let dir = dirname(exe); ; ) {
    if (holdsSources(dir)) return dir;
    const up = dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  throw new Error(`native: can't find the runtime sources for ${exe}; set NATIVE_SDK_ROOT to the directory that holds runtime/ and host/`);
}

export const ROOT = NATIVE_BINARY ? binaryRoot() : resolve(dirname(fileURLToPath(import.meta.url)), "..");

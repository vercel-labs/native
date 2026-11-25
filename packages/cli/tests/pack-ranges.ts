// The dependency ranges the packed CLI records: the workspace's `workspace:*` optional
// dependencies (the dev hosts, ANGLE) become their own versions, because npm rejects a tarball
// that keeps the workspace protocol (EUNSUPPORTEDPROTOCOL), and the CLI's platform packages are
// the CLI's version.
//   npm test

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { publishedOptionalDependencies, workspacePackageSlug, workspaceRanges } from "../scripts/package-ranges.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const versions: Record<string, string> = {
  "@native-sdk/dev-host-linux-x64": "0.20.0",
  "@native-sdk/angle-win32-x64": "0.20.0",
};
const versionOf = (name: string): string | null => versions[name] ?? null;

// A workspace range becomes that package's version; a registry range is kept as written.
const packed = publishedOptionalDependencies(
  { "@native-sdk/dev-host-linux-x64": "workspace:*", "@scriptc/libnode-linux-x64-gnu": "^0.4.16" },
  { "@native-sdk/cli-linux-x64": "0.20.0" },
  versionOf,
);
check("a workspace range becomes the package's version", packed["@native-sdk/dev-host-linux-x64"] === "0.20.0", JSON.stringify(packed));
check("a registry range is kept", packed["@scriptc/libnode-linux-x64-gnu"] === "^0.4.16", JSON.stringify(packed));
check("the CLI's platform package is the CLI's version", packed["@native-sdk/cli-linux-x64"] === "0.20.0", JSON.stringify(packed));

// A workspace dependency this publisher cannot name, or one with no package beside it, is an
// error rather than an `npm i` range npm would reject.
const throws = (fn: () => unknown): boolean => {
  try {
    fn();
    return false;
  } catch {
    return true;
  }
};
check(
  "a workspace range outside @native-sdk is refused",
  throws(() => publishedOptionalDependencies({ "left-pad": "workspace:*" }, {}, versionOf)),
);
check(
  "a workspace package with no version is refused",
  throws(() => publishedOptionalDependencies({ "@native-sdk/dev-host-ios-arm64": "workspace:*" }, {}, versionOf)),
);

// The guard the packer runs on what it wrote.
check("a leftover workspace range is reported", workspaceRanges({ dependencies: { a: "workspace:*" } }).length === 1);
check(
  "clean ranges are not reported",
  workspaceRanges({ dependencies: { a: "^1.0.0" }, optionalDependencies: { b: "2.0.0" } }).length === 0,
);

// The CLI manifest as the workspace holds it: packed with the versions beside it, it keeps no
// workspace range — the state that made npm reject the first tarballs.
const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const manifest = JSON.parse(readFileSync(join(root, "package.json"), "utf8")) as {
  optionalDependencies?: Record<string, string>;
};
const real = (name: string): string | null => {
  const slug = workspacePackageSlug(name);
  if (slug === null) return null;
  const path = join(root, "..", slug, "package.json");
  if (!existsSync(path)) return null;
  return (JSON.parse(readFileSync(path, "utf8")) as { version: string }).version;
};
const realPacked = publishedOptionalDependencies(manifest.optionalDependencies ?? {}, {}, real);
check(
  "the CLI's own optional dependencies pack without a workspace range",
  workspaceRanges({ optionalDependencies: realPacked }).length === 0,
  JSON.stringify(realPacked),
);
check(
  "the CLI's dev hosts and ANGLE are named by version",
  realPacked["@native-sdk/dev-host-linux-x64"] !== undefined &&
    !realPacked["@native-sdk/dev-host-linux-x64"].startsWith("workspace:") &&
    !realPacked["@native-sdk/angle-win32-x64"].startsWith("workspace:"),
  JSON.stringify(realPacked),
);

process.exit(failed === 0 ? 0 : 1);

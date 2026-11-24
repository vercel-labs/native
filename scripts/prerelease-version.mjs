// Stamps a prerelease version (for example 0.20.0-next.42) onto the packages the prerelease
// workflow publishes, and points the CLI's optional dependencies at that same version.
//
// `pnpm pack` rewrites `workspace:*` to each package's own version. The packages here are not
// published yet, so the CLI must ask for the prerelease's platform packages rather than a stable
// version that does not exist. The script edits the working tree only; a run in CI is never pushed.

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const version = process.argv[2];
if (typeof version !== "string" || !/^\d+\.\d+\.\d+-next\.\d+$/.test(version)) {
  console.error("usage: node scripts/prerelease-version.mjs <major.minor.patch-next.N>");
  process.exit(1);
}

const root = process.cwd();
const packages = [
  "packages/cli",
  "packages/angle-win32-x64",
  "packages/dev-host-darwin-arm64",
  "packages/dev-host-darwin-x64",
  "packages/dev-host-linux-arm64",
  "packages/dev-host-linux-x64",
  "packages/dev-host-win32-x64",
];

for (const dir of packages) {
  const file = join(root, dir, "package.json");
  const pkg = JSON.parse(readFileSync(file, "utf8"));
  pkg.version = version;
  for (const field of ["dependencies", "optionalDependencies"]) {
    const deps = pkg[field];
    if (deps === undefined) continue;
    for (const name of Object.keys(deps)) {
      if (name.startsWith("@native-sdk/")) deps[name] = version;
    }
  }
  writeFileSync(file, JSON.stringify(pkg, null, 2) + "\n");
  console.log(`prerelease: ${pkg.name}@${version}`);
}

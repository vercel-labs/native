// The dependency ranges a published CLI package records.
//
// The workspace manifest names its own packages with `workspace:` ranges (the dev hosts, ANGLE).
// npm refuses a tarball that carries one with EUNSUPPORTEDPROTOCOL, so the published manifest names
// their versions instead — the versions this release publishes beside the CLI — and the CLI's
// platform packages its own version. A range that already names the registry is kept as it is.

/** The repository directory of an `@native-sdk/` package, or null for another scope. */
export function workspacePackageSlug(name: string): string | null {
  return name.startsWith("@native-sdk/") ? name.slice("@native-sdk/".length) : null;
}

/**
 * `optionalDependencies` as the published package records them.
 *
 * @param optional the workspace manifest's own optional dependencies
 * @param platformVersions the CLI platform packages, name to range (this release's version)
 * @param version a workspace package's current version, or null when there is no such package
 */
export function publishedOptionalDependencies(
  optional: Record<string, string>,
  platformVersions: Record<string, string>,
  version: (name: string) => string | null,
): Record<string, string> {
  const published: Record<string, string> = {};
  for (const [name, range] of Object.entries(optional)) {
    if (!range.startsWith("workspace:")) {
      published[name] = range;
      continue;
    }
    if (workspacePackageSlug(name) === null) {
      throw new Error(`${name} is a workspace dependency outside @native-sdk, so it cannot be published`);
    }
    const resolved = version(name);
    if (resolved === null || resolved === "") throw new Error(`no version for the workspace package ${name}`);
    published[name] = resolved;
  }
  for (const [name, range] of Object.entries(platformVersions)) published[name] = range;
  return published;
}

/** The dependencies whose range npm refuses outside a workspace, as `field: name=range` lines. */
export function workspaceRanges(manifest: {
  dependencies?: Record<string, string>;
  optionalDependencies?: Record<string, string>;
}): string[] {
  const found: string[] = [];
  for (const field of ["dependencies", "optionalDependencies"] as const) {
    for (const [name, range] of Object.entries(manifest[field] ?? {})) {
      if (typeof range === "string" && range.startsWith("workspace:")) found.push(`${field}: ${name}=${range}`);
    }
  }
  return found;
}

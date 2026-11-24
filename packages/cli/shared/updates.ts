// The update document an app checks, and the version comparison that decides whether it is
// newer. Shared by the compiler, which writes the app's own version into the bundle, and the
// runtime, which reads the document.

/** What the build writes into the bundle for the runtime to read. */
export interface UpdateConfig {
  /** The update document's URL. */
  url: string;
  /** The version the running app was built as. */
  version: string;
  /** The app's name, for messages. */
  name: string;
}

/** The update document a check fetched. */
export interface UpdateDocument {
  version: string;
  /** Where the update's artifact lives; "" when the document names none. */
  url: string;
  notes: string;
}

/** The numbers and prerelease of a version, in the `major.minor.patch[-prerelease]` form. */
function versionParts(raw: string): { numbers: number[]; prerelease: string } {
  const m = /^\s*v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?/.exec(raw);
  if (m === null) return { numbers: [0, 0, 0], prerelease: "" };
  return { numbers: [Number(m[1]), Number(m[2] ?? 0), Number(m[3] ?? 0)], prerelease: m[4] ?? "" };
}

/**
 * -1, 0 or 1 as `a` is older than, equal to or newer than `b`. Missing numbers count as zero,
 * and a prerelease is older than the release with the same numbers, as semantic versioning has
 * it.
 */
export function compareVersions(a: string, b: string): number {
  const left = versionParts(a), right = versionParts(b);
  for (let i = 0; i < 3; i++) {
    if (left.numbers[i] !== right.numbers[i]) return left.numbers[i] < right.numbers[i] ? -1 : 1;
  }
  if (left.prerelease === right.prerelease) return 0;
  if (left.prerelease === "") return 1;
  if (right.prerelease === "") return -1;
  return left.prerelease < right.prerelease ? -1 : 1;
}

/** Reads an update document. Null when it names no version the app can compare. */
export function parseUpdateDocument(value: unknown): UpdateDocument | null {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  if (typeof record["version"] !== "string" || !/^\s*v?\d/.test(record["version"])) return null;
  const url = typeof record["url"] === "string" && /^https?:\/\//i.test(record["url"]) ? record["url"] : "";
  const notes = typeof record["notes"] === "string" ? record["notes"] : "";
  return { version: record["version"].trim(), url, notes };
}

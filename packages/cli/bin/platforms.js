// The platform packages that carry the native `native` executable, one per OS and CPU.

export const platforms = [
  { name: "darwin-arm64", os: "darwin", cpu: "arm64" },
  { name: "darwin-x64", os: "darwin", cpu: "x64" },
  { name: "linux-arm64", os: "linux", cpu: "arm64" },
  { name: "linux-x64", os: "linux", cpu: "x64" },
  { name: "win32-x64", os: "win32", cpu: "x64" },
];

/** The npm package of a platform's executable. */
export function packageName(platform) {
  return `@native-sdk/cli-${platform.name}`;
}

/** The executable's file name on an OS. */
export function executableName(os = process.platform) {
  return os === "win32" ? "native.exe" : "native";
}

/** The platform of this process, or undefined when there is no executable for it. */
export function hostPlatform() {
  return platforms.find((p) => p.os === process.platform && p.cpu === process.arch);
}

export function hostDescription() {
  return `${process.platform}-${process.arch}`;
}

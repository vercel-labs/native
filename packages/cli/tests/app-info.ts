// Reading an app's product metadata from its page: the web app manifest it links, the
// <link rel="icon"> fallback, and the bundle identity a release build writes.
//   npm test

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appInfoOf, bundledInfo, defaultBundleIdentifier, versionOf } from "../compiler/app-info.ts";
import { writeInfoPlist } from "../compiler/build.ts";
import { encodePng } from "./png.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-app-info-"));
const png = (side: number, colour: number[]): Buffer => encodePng(side, side, () => [...colour, 255]);

// An app with a web app manifest: its name, short name, id, version, icon and update URL.
const full = join(dir, "full");
mkdirSync(full, { recursive: true });
writeFileSync(join(full, "icon.png"), png(64, [10, 20, 30]));
writeFileSync(join(full, "small.png"), png(16, [30, 20, 10]));
writeFileSync(join(full, "app.webmanifest"), JSON.stringify({
  name: "Notes Native",
  short_name: "Notes",
  id: "dev.example.notes",
  version: "3.2.1",
  icons: [
    { src: "small.png", sizes: "16x16", type: "image/png" },
    { src: "icon.png", sizes: "64x64", type: "image/png" },
  ],
  update_url: "https://updates.example.com/notes.json",
}));
writeFileSync(join(full, "index.html"), `<!doctype html><html><head>
<title>Ignored Page Title</title>
<link rel="manifest" href="app.webmanifest">
</head><body></body></html>`);
const info = appInfoOf(join(full, "index.html"));
check("the manifest names the app", info.name === "Notes Native", info.name);
check("the manifest's short name is the short name", info.shortName === "Notes", info.shortName);
check("the manifest's id is the bundle identifier", info.id === "dev.example.notes", info.id);
check("the manifest's version is the version", info.version === "3.2.1", info.version);
check("the manifest's update URL turns the update check on",
  info.updateUrl === "https://updates.example.com/notes.json", String(info.updateUrl));
check("the largest icon is chosen", info.icon !== null && info.icon.width === 64, JSON.stringify(info.icon));
check("the icon is a PNG the build measured", info.icons[0]?.type === "image/png" && info.icons[0]?.source === join(full, "icon.png"),
  JSON.stringify(info.icons));
check("the manifest file is recorded", info.manifest === join(full, "app.webmanifest"), String(info.manifest));
check("reading a complete manifest warns about nothing", info.warnings.length === 0, info.warnings.join("; "));

// A page without a manifest: its <title> names it and <link rel="icon"> gives the icon.
const bare = join(dir, "bare");
mkdirSync(bare, { recursive: true });
writeFileSync(join(bare, "favicon.png"), png(32, [1, 2, 3]));
writeFileSync(join(bare, "index.html"), `<!doctype html><html><head>
<title>Plain Page</title>
<link rel="icon" href="favicon.png" type="image/png">
</head><body></body></html>`);
const plain = appInfoOf(join(bare, "index.html"));
check("the page title is the name without a manifest", plain.name === "Plain Page", plain.name);
check("the bundle identifier is derived from the name", plain.id === defaultBundleIdentifier("Plain Page"), plain.id);
check("the version defaults to 1.0.0", plain.version === "1.0.0", plain.version);
check("the link rel=icon is the icon", plain.icon !== null && plain.icon.width === 32, JSON.stringify(plain.icon));
check("no update URL means no update check", plain.updateUrl === null, String(plain.updateUrl));

// A manifest that doesn't parse is a warning, and the page's own title and icon still count.
const broken = join(dir, "broken");
mkdirSync(broken, { recursive: true });
writeFileSync(join(broken, "icon.png"), png(16, [9, 9, 9]));
writeFileSync(join(broken, "index.html"), `<!doctype html><html><head>
<title>Broken Manifest</title>
<link rel="manifest" href="nope.webmanifest">
<link rel="icon" href="icon.png">
</head><body></body></html>`);
writeFileSync(join(broken, "nope.webmanifest"), "{ not json");
const bad = appInfoOf(join(broken, "index.html"));
check("a manifest that isn't JSON warns", bad.warnings.some((w) => w.includes("not valid JSON")), bad.warnings.join("; "));
check("a broken manifest falls back to the page title", bad.name === "Broken Manifest", bad.name);
check("a broken manifest still falls back to the page icon", bad.icon !== null, JSON.stringify(bad.icon));

// The environment overrides what the manifest says, so a release pipeline can version a build
// without editing the app.
process.env["NATIVE_APP_ID"] = "com.example.pipeline";
process.env["NATIVE_APP_VERSION"] = "9.8.7";
const overridden = appInfoOf(join(full, "index.html"));
check("NATIVE_APP_ID overrides the manifest id", overridden.id === "com.example.pipeline", overridden.id);
check("NATIVE_APP_VERSION overrides the manifest version", overridden.version === "9.8.7", overridden.version);
delete process.env["NATIVE_APP_ID"];
delete process.env["NATIVE_APP_VERSION"];

check("an invalid version is read as major.minor.patch", versionOf("v2.1-beta") === "2.1.0", String(versionOf("v2.1-beta")));
check("a version with one number is complete", versionOf("4") === "4.0.0", String(versionOf("4")));
check("a version that isn't a number is rejected", versionOf("latest") === null, String(versionOf("latest")));

// Without a manifest or a <title>, a package.json beside the page names the app, and the app's
// directory is the last resort.
const packaged = join(dir, "packaged");
mkdirSync(packaged, { recursive: true });
writeFileSync(join(packaged, "index.html"), `<!doctype html><html><head></head><body></body></html>`);
writeFileSync(join(packaged, "package.json"), JSON.stringify({ name: "@acme/tide", productName: "Tide Home" }));
const pkgInfo = appInfoOf(join(packaged, "index.html"));
check("productName names the app without a title", pkgInfo.name === "Tide Home", pkgInfo.name);
check("the identifier comes from the display name", pkgInfo.id === "dev.native-sdk.tide-home", pkgInfo.id);

const scopedDir = join(dir, "scoped");
mkdirSync(scopedDir, { recursive: true });
writeFileSync(join(scopedDir, "index.html"), `<!doctype html><html><head></head><body></body></html>`);
writeFileSync(join(scopedDir, "package.json"), JSON.stringify({ name: "@acme/relay-app" }));
check("a package name without a productName drops its scope", appInfoOf(join(scopedDir, "index.html")).name === "relay-app",
  appInfoOf(join(scopedDir, "index.html")).name);

const unnamed = join(dir, "unnamed-app");
mkdirSync(unnamed, { recursive: true });
writeFileSync(join(unnamed, "index.html"), `<!doctype html><html><head></head><body></body></html>`);
check("the app directory is the last resort for the name", appInfoOf(join(unnamed, "index.html")).name === "unnamed-app",
  appInfoOf(join(unnamed, "index.html")).name);

// The manifest still wins over the package.
writeFileSync(join(full, "package.json"), JSON.stringify({ name: "package-name", productName: "Package Name" }));
check("the manifest names the app before the package does", appInfoOf(join(full, "index.html")).name === "Notes Native",
  appInfoOf(join(full, "index.html")).name);

// The bundle carries the facts at paths it owns, so the runtime and the installers read one file.
const bundled = bundledInfo(info);
check("the bundle's app.json names the app", bundled.name === "Notes Native" && bundled.id === "dev.example.notes" &&
  bundled.version === "3.2.1", JSON.stringify(bundled));
check("the bundle's app.json points at the copied icon", bundled.icon === ".native/icon.png", String(bundled.icon));

// The Info.plist a macOS release bundle gets from the same facts.
const app = join(dir, "Plated.app");
writeInfoPlist(app, "Plated", "Plated", info, "AppIcon");
const plist = readFileSync(join(app, "Contents", "Info.plist"), "utf8");
check("the plist carries the manifest's bundle identifier", plist.includes("<string>dev.example.notes</string>"), plist);
check("the plist carries the manifest's version", plist.includes("<key>CFBundleShortVersionString</key><string>3.2.1</string>"), plist);
check("the plist carries the display name", plist.includes("<key>CFBundleDisplayName</key><string>Notes Native</string>"), plist);
check("the plist names the icns", plist.includes("<key>CFBundleIconFile</key><string>AppIcon</string>"), plist);

process.exit(failed === 0 ? 0 : 1);

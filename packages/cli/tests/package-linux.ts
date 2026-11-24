// Linux packaging: the app facts a .desktop entry and icon come from, the entry itself, and the
// ar + tar.gz archives a .deb is. Ubuntu's dpkg-deb reads them; these checks run anywhere.
//   npm test

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gunzipSync } from "node:zlib";
import {
  debArch, defaultIcon, desktopEntry, linuxAppOf, packageNameOf, packageVersionOf, tarGz, writeDeb,
  type LinuxApp,
} from "../compiler/package-linux.ts";
import type { BuildResult } from "../compiler/build.ts";
import { decodePng, encodePng } from "./png.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-package-linux-"));

// Names and versions Debian and the desktop entry accept.
check("a package name is lowercase and hyphenated", packageNameOf("Release Notes!") === "release-notes", packageNameOf("Release Notes!"));
check("a package name starts with a letter or digit", packageNameOf("--Notes--") === "notes", packageNameOf("--Notes--"));
check("an empty name becomes app", packageNameOf("!!!") === "app", packageNameOf("!!!"));
check("a version keeps three numbers", packageVersionOf("v3.2-beta") === "3.2.0", packageVersionOf("v3.2-beta"));
check("a version defaults to 1.0.0", packageVersionOf("latest") === "1.0.0", packageVersionOf("latest"));
check("arm64 is a Debian architecture", debArch("arm64") === "arm64", debArch("arm64"));
check("x64 is amd64", debArch("x64") === "amd64", debArch("x64"));

// The bundle's app.json names the app when a release build wrote one.
const res = join(dir, "bundle.resources");
mkdirSync(join(res, ".native"), { recursive: true });
writeFileSync(join(res, ".native", "icon.png"), encodePng(64, 64, () => [1, 2, 3, 255]));
writeFileSync(join(res, ".native", "app.json"), JSON.stringify({
  name: "Notes Native",
  shortName: "Notes",
  id: "dev.example.notes",
  version: "2.1.0",
  updateUrl: null,
  icon: ".native/icon.png",
}));
const fromBundle = linuxAppOf(res, join(dir, "none.html"), join(dir, "notes"));
check("app.json names the package", fromBundle.name === "Notes Native" && fromBundle.pkg === "notes-native", JSON.stringify(fromBundle));
check("app.json names the version", fromBundle.version === "2.1.0", fromBundle.version);
check("app.json's icon is measured", fromBundle.icon !== null && fromBundle.iconWidth === 64, JSON.stringify(fromBundle));

// A plain build has no app.json: the page's manifest or its title and icon answer.
const page = join(dir, "page");
mkdirSync(page, { recursive: true });
writeFileSync(join(page, "icon.png"), encodePng(48, 48, () => [9, 9, 9, 255]));
writeFileSync(join(page, "app.webmanifest"), JSON.stringify({
  name: "Plain Notes",
  version: "4.0",
  icons: [{ src: "icon.png", sizes: "48x48", type: "image/png" }],
}));
writeFileSync(join(page, "index.html"), `<!doctype html><html><head><title>Ignored</title>
<link rel="manifest" href="app.webmanifest"></head><body></body></html>`);
const fromPage = linuxAppOf(join(page, "missing.resources"), join(page, "index.html"), join(dir, "plain-notes"));
check("the page's manifest names the package", fromPage.name === "Plain Notes" && fromPage.pkg === "plain-notes", JSON.stringify(fromPage));
check("the page's manifest names the version", fromPage.version === "4.0.0", fromPage.version);
check("the page's icon is measured", fromPage.icon !== null && fromPage.iconWidth === 48, JSON.stringify(fromPage));

// With no metadata at all the executable's name is the app, and it still gets an icon.
const bare = linuxAppOf(join(dir, "bare.resources"), join(dir, "nope.html"), join(dir, "my-app"));
check("a bare app is named for its executable", bare.name === "my-app" && bare.pkg === "my-app", JSON.stringify(bare));
check("a bare app has no icon of its own", bare.icon === null, String(bare.icon));
const fallbackFile = join(dir, "default.png");
writeFileSync(fallbackFile, defaultIcon(64));
const decoded = decodePng(fallbackFile);
check("the default icon is a 64x64 PNG", decoded.w === 64 && decoded.h === 64, `${decoded.w}x${decoded.h}`);
check("the default icon is opaque in its middle", decoded.rgba[(32 * 64 + 32) * 4 + 3] === 255);

const app: LinuxApp = {
  name: "Notes Native", pkg: "notes-native", iconName: "notes-native", version: "2.1.0",
  icon: null, iconWidth: 0, iconHeight: 0,
};
const entry = desktopEntry(app);
check("the desktop entry is an application", entry.includes("Type=Application"));
check("the desktop entry runs the executable", entry.includes("Exec=notes-native"));
check("the desktop entry names the icon", entry.includes("Icon=notes-native"));
check("the desktop entry carries the version", entry.includes("X-AppImage-Version=2.1.0"));

// The tar and ar writers: a control.tar.gz holds the control file, and the .deb starts with
// ar's magic and its three members in order.
const controlTar = tarGz([{ path: "./control", type: "file", mode: 0o644, data: Buffer.from("Package: notes\n") }]);
check("the control tar is gzip", controlTar[0] === 0x1f && controlTar[1] === 0x8b, `${controlTar[0]} ${controlTar[1]}`);
check("the control tar holds the control file", gunzipSync(controlTar).toString("utf8").includes("Package: notes"));

const exe = join(dir, "notes");
writeFileSync(exe, "#!/bin/sh\nexit 0\n", { mode: 0o755 });
const result = {
  output: exe,
  resources: res,
  assets: { count: 0, bytes: 0 },
  nativeMs: 0,
  scriptcMs: 0,
  cached: false,
} as BuildResult;
const deb = join(dir, "notes_2.1.0_amd64.deb");
writeDeb(deb, result, app, "x64");
const bytes = readFileSync(deb);
check("the .deb starts with ar's magic", bytes.subarray(0, 8).toString("ascii") === "!<arch>\n", bytes.subarray(0, 8).toString("ascii"));
const text = bytes.toString("latin1");
check("the .deb holds debian-binary", text.includes("debian-binary"));
check("the .deb holds a control archive", text.includes("control.tar.gz"));
check("the .deb holds a data archive", text.includes("data.tar.gz"));
const idx = text.indexOf("control.tar.gz");
const sizeField = text.slice(idx + 48, idx + 58).trim();
const control = gunzipSync(bytes.subarray(idx + 60, idx + 60 + Number(sizeField))).toString("utf8");
check("the control names the package and version", control.includes("Package: notes-native") && control.includes("Version: 2.1.0"), control);
check("the control names the architecture", control.includes("Architecture: amd64"), control);

process.exit(failed === 0 ? 0 : 1);

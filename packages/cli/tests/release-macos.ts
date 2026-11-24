// The macOS release inputs that don't need a Mac: the entitlements a signed app carries, the
// names a .dmg takes, and the identity and notary credentials read from the environment.
//   npm test

import { dmgName, dmgVolumeName, entitlementsPlist, notaryCredentials, signIdentity } from "../compiler/package-macos.ts";
import type { AppInfo } from "../compiler/app-info.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const info: AppInfo = {
  name: "Notes Native",
  shortName: "Notes Native",
  id: "dev.example.notes",
  version: "2.4.0",
  icons: [],
  icon: null,
  updateUrl: null,
  manifest: null,
  warnings: [],
};

const plist = entitlementsPlist();
check("the entitlements are a plist", plist.includes("<!DOCTYPE plist") && plist.includes("</plist>"));
check("the hardened runtime has no exceptions", /<dict>\s*<\/dict>/.test(plist), plist);

check("the dmg is named for the app and version", dmgName(info) === "Notes-Native-2.4.0.dmg", dmgName(info));
check("the dmg volume is the app's name", dmgVolumeName(info) === "Notes Native 2.4.0", dmgVolumeName(info));
const risky = { ...info, shortName: "A/B:C" };
check("a short name is safe in a file name", dmgName(risky) === "A-B-C-2.4.0.dmg", dmgName(risky));

const saved = {
  identity: process.env["NATIVE_SIGN_IDENTITY"],
  appleId: process.env["NATIVE_NOTARY_APPLE_ID"],
  password: process.env["NATIVE_NOTARY_PASSWORD"],
  teamId: process.env["NATIVE_NOTARY_TEAM_ID"],
  profile: process.env["NATIVE_NOTARY_KEYCHAIN_PROFILE"],
};
function restore(): void {
  for (const [key, value] of [
    ["NATIVE_SIGN_IDENTITY", saved.identity],
    ["NATIVE_NOTARY_APPLE_ID", saved.appleId],
    ["NATIVE_NOTARY_PASSWORD", saved.password],
    ["NATIVE_NOTARY_TEAM_ID", saved.teamId],
    ["NATIVE_NOTARY_KEYCHAIN_PROFILE", saved.profile],
  ] as const) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
}
for (const key of ["NATIVE_SIGN_IDENTITY", "NATIVE_NOTARY_APPLE_ID", "NATIVE_NOTARY_PASSWORD", "NATIVE_NOTARY_TEAM_ID", "NATIVE_NOTARY_KEYCHAIN_PROFILE"]) {
  delete process.env[key];
}

check("an unnamed identity signs ad-hoc", signIdentity() === null, String(signIdentity()));
process.env["NATIVE_SIGN_IDENTITY"] = "Developer ID Application: Example (TEAM)";
check("the identity comes from the environment", signIdentity() === "Developer ID Application: Example (TEAM)", String(signIdentity()));
process.env["NATIVE_SIGN_IDENTITY"] = "   ";
check("a blank identity is no identity", signIdentity() === null, String(signIdentity()));

check("no credentials means no notarization", notaryCredentials() === null, JSON.stringify(notaryCredentials()));
process.env["NATIVE_NOTARY_APPLE_ID"] = "dev@example.com";
process.env["NATIVE_NOTARY_PASSWORD"] = "secret";
let partial = "";
try {
  notaryCredentials();
} catch (err) {
  partial = err instanceof Error ? err.message : String(err);
}
check("a partial credential set is an error", partial.includes("NATIVE_NOTARY_TEAM_ID"), partial);
process.env["NATIVE_NOTARY_TEAM_ID"] = "TEAM";
check("the credentials are all passed to notarytool",
  JSON.stringify(notaryCredentials()) === JSON.stringify(["--apple-id", "dev@example.com", "--password", "secret", "--team-id", "TEAM"]),
  JSON.stringify(notaryCredentials()));
delete process.env["NATIVE_NOTARY_APPLE_ID"];
delete process.env["NATIVE_NOTARY_PASSWORD"];
delete process.env["NATIVE_NOTARY_TEAM_ID"];
process.env["NATIVE_NOTARY_KEYCHAIN_PROFILE"] = "release";
check("a keychain profile stands in for the credentials", JSON.stringify(notaryCredentials()) === JSON.stringify(["--keychain-profile", "release"]),
  JSON.stringify(notaryCredentials()));

restore();
process.exit(failed === 0 ? 0 : 1);

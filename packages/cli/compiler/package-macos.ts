// A macOS release: the hardened-runtime signature the app ships with, notarization when the
// notary credentials are in the environment, and the .dmg people install it from.
//
// Nothing secret belongs in the repository: an identity comes from NATIVE_SIGN_IDENTITY and the
// notary credentials from NATIVE_NOTARY_APPLE_ID, NATIVE_NOTARY_PASSWORD and
// NATIVE_NOTARY_TEAM_ID, or from the keychain profile NATIVE_NOTARY_KEYCHAIN_PROFILE. Without an
// identity the app is signed ad-hoc, which runs on the machine that built it; without notary
// credentials the build stops after signing.

import { copyFileSync, cpSync, existsSync, linkSync, mkdirSync, mkdtempSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, relative } from "node:path";
import { spawnSync } from "node:child_process";
import type { AppInfo } from "./app-info.ts";

/** What a release wrote, for the build's summary. */
export interface MacReleaseResult {
  dmg: string;
  /** "developer-id" for NATIVE_SIGN_IDENTITY, "ad-hoc" without one. */
  signed: "developer-id" | "ad-hoc";
  notarized: boolean;
}

/**
 * The entitlements a release app is signed with. The hardened runtime is what the signature
 * turns on; the dictionary is empty because the app asks for no exceptions: it runs its own
 * compiled machine code, loads only system libraries, and needs no JIT or unsigned memory.
 */
export function entitlementsPlist(): string {
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0">',
    "<dict>",
    "</dict>",
    "</plist>",
    "",
  ].join("\n");
}

/** The .dmg's file name: the app's short name and version, without path separators. */
export function dmgName(info: AppInfo): string {
  const name = info.shortName.replace(/[\/\\:]/g, "-").replace(/\s+/g, "-");
  return `${name === "" ? "app" : name}-${info.version}.dmg`;
}

/** The volume name Finder shows for the .dmg. */
export function dmgVolumeName(info: AppInfo): string {
  return `${info.shortName} ${info.version}`;
}

/** The signing identity from the environment, or null for an ad-hoc signature. */
export function signIdentity(): string | null {
  const value = process.env["NATIVE_SIGN_IDENTITY"];
  return value === undefined || value.trim() === "" ? null : value.trim();
}

/** The notarytool credentials from the environment, or null when notarization wasn't asked for.
 *  A partial set is a configuration error: notarizing with the wrong password would fail later,
 *  after a build and a signing. */
export function notaryCredentials(): string[] | null {
  const profile = process.env["NATIVE_NOTARY_KEYCHAIN_PROFILE"]?.trim();
  if (profile !== undefined && profile !== "") return ["--keychain-profile", profile];
  const appleId = process.env["NATIVE_NOTARY_APPLE_ID"]?.trim();
  const password = process.env["NATIVE_NOTARY_PASSWORD"];
  const teamId = process.env["NATIVE_NOTARY_TEAM_ID"]?.trim();
  const set = [appleId, password, teamId].filter((v) => v !== undefined && v !== "").length;
  if (set === 0) return null;
  if (set !== 3) {
    throw new Error("native: notarization needs NATIVE_NOTARY_APPLE_ID, NATIVE_NOTARY_PASSWORD and NATIVE_NOTARY_TEAM_ID (or NATIVE_NOTARY_KEYCHAIN_PROFILE)");
  }
  return ["--apple-id", appleId as string, "--password", password as string, "--team-id", teamId as string];
}

/** Runs a tool and fails the build with its own message when it doesn't succeed. */
function run(tool: string, args: string[], what: string, env?: NodeJS.ProcessEnv): { stdout: string; stderr: string } {
  const r = spawnSync(tool, args, { encoding: "utf8", env: env === undefined ? process.env : { ...process.env, ...env } });
  if (r.error) throw new Error(`native: ${what}: ${tool} couldn't run (${r.error.message})`);
  if (r.status !== 0) {
    const detail = (r.stderr || r.stdout).trim();
    throw new Error(`native: ${what} failed${detail === "" ? "" : `\n${detail}`}`);
  }
  return { stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

/** Submits a file to notarytool and waits for the verdict, printing the log when it isn't
 *  accepted. */
function notarize(file: string, credentials: string[]): void {
  const r = spawnSync("xcrun", ["notarytool", "submit", "--wait", ...credentials, "--output-format", "json", file], { encoding: "utf8" });
  if (r.error) throw new Error(`native: notarization: xcrun couldn't run (${r.error.message})`);
  let verdict: { id?: string; status?: string; message?: string } = {};
  try {
    verdict = JSON.parse(r.stdout) as typeof verdict;
  } catch {
    // A tool that printed something else reports through its stderr and exit status below.
  }
  if (r.status === 0 && verdict.status === "Accepted") return;
  const id = verdict.id;
  const log = id === undefined ? "" : (() => {
    const l = spawnSync("xcrun", ["notarytool", "log", id, ...credentials], { encoding: "utf8" });
    return l.stdout === "" ? "" : `\n${l.stdout.trim()}`;
  })();
  throw new Error(`native: notarization failed${verdict.message === undefined ? "" : `: ${verdict.message}`}${log}\n${(r.stderr || "").trim()}`);
}

/** The bytes a folder holds, for the disk image's size: files, not the symbolic links inside it
 *  (the Applications link is not a copy of the folder it names). */
function folderBytes(dir: string): number {
  let total = 0;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name);
    if (entry.isDirectory()) total += folderBytes(p);
    else if (entry.isFile()) total += statSync(p).size;
  }
  return total;
}

/**
 * Signs and packages a built .app: writes its entitlements, signs it with the hardened runtime,
 * notarizes and staples it when credentials are present, then makes a .dmg with an Applications
 * link, signs that, and notarizes and staples it too. The .dmg lands beside the .app.
 */
export function packageMacApp(paths: { bundle: string; executable: string; alias: string }, info: AppInfo): MacReleaseResult {
  const { bundle, executable, alias } = paths;
  const identity = signIdentity();
  const credentials = notaryCredentials();
  if (credentials !== null && identity === null) {
    throw new Error("native: notarization needs a Developer ID identity in NATIVE_SIGN_IDENTITY");
  }
  if (!existsSync(executable)) throw new Error(`native: ${relative(process.cwd(), bundle)} has no executable`);

  // The staging area sits beside the .dmg, on the volume the image is written to. A temporary
  // directory under TMPDIR can be a smaller disk or a full one, and hdiutil reports that as no
  // space at all even when the output's volume has plenty.
  let work: string;
  try {
    work = mkdtempSync(join(dirname(bundle), ".native-release-"));
  } catch {
    work = mkdtempSync(join(tmpdir(), "native-release-"));
  }
  try {
    const entitlements = join(work, "app.entitlements");
    writeFileSync(entitlements, entitlementsPlist());
    const sign = ["--force", "--options", "runtime", "--entitlements", entitlements, "--sign", identity ?? "-"];
    if (identity !== null) sign.push("--timestamp");
    run("codesign", [...sign, bundle], "codesigning");
    run("codesign", ["--verify", "--strict", "--verbose=2", bundle], "verifying the signature");
    // codesign may replace the executable rather than write into it, which leaves the hard link
    // the output path is made from pointing at the old file. Point it at the signed one again.
    if (alias !== bundle) {
      rmSync(alias, { force: true });
      try {
        linkSync(executable, alias);
      } catch {
        copyFileSync(executable, alias);
      }
    }
    console.error(`native: signed ${basename(bundle)} (${identity === null ? "ad-hoc" : "Developer ID"})`);

    // Notarize the app itself first: a ticket stapled to it travels with the app when someone
    // copies it out of the .dmg. The zip is what notarytool takes; ditto keeps signatures and
    // symlinks intact.
    let notarized = false;
    if (credentials !== null) {
      const zip = join(work, "app.zip");
      run("ditto", ["-c", "-k", "--keepParent", bundle, zip], "zipping the app for notarization");
      notarize(zip, credentials);
      run("xcrun", ["stapler", "staple", bundle], "stapling the app");
      console.error(`native: notarized ${basename(bundle)}`);
      notarized = true;
    }

    const stage = join(work, "dmg");
    mkdirSync(stage);
    cpSync(bundle, join(stage, basename(bundle)), { recursive: true, verbatimSymlinks: true });
    symlinkSync("/Applications", join(stage, "Applications"));
    const dmg = join(dirname(bundle), dmgName(info));
    rmSync(dmg, { force: true });
    // hdiutil sizes the image from the folder itself, and its estimate can come up short for a
    // large app; when it says so, the image is made again with a size measured from the staged
    // files. Its own scratch space is the staging folder, which is on the output's volume.
    const create = (extra: string[]): void => {
      run("hdiutil", ["create", "-volname", dmgVolumeName(info), "-srcfolder", stage, ...extra,
        "-ov", "-format", "UDZO", dmg], "creating the disk image", { TMPDIR: work });
    };
    try {
      create([]);
    } catch (err) {
      if (!/No space left on device/.test(err instanceof Error ? err.message : String(err))) throw err;
      create(["-size", `${Math.ceil(folderBytes(stage) / (1024 * 1024)) + 64}m`]);
    }
    if (identity !== null) {
      run("codesign", ["--force", "--sign", identity, "--timestamp", dmg], "signing the disk image");
    }
    if (credentials !== null) {
      notarize(dmg, credentials);
      run("xcrun", ["stapler", "staple", dmg], "stapling the disk image");
    }
    const mb = (statSync(dmg).size / 1024 / 1024).toFixed(1);
    console.error(`native: ${relative(process.cwd(), dmg)} (${mb} MB)`);
    return { dmg, signed: identity === null ? "ad-hoc" : "developer-id", notarized };
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

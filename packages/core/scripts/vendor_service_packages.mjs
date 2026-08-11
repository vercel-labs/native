#!/usr/bin/env node
// Resolve explicit npm versions only during `native vendor`, then copy every
// resolved package into the app-owned service vendor tree. Builds never run
// npm and accept these bytes only after verifying the manifest hash.

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const appRoot = path.resolve(process.argv[2] ?? ".");
const requested = process.argv.slice(3);
if (requested.length === 0 || requested.some((spec) => !/^(?:@[a-z0-9._-]+\/)?[a-z0-9._-]+@\d+\.\d+\.\d+$/i.test(spec))) {
  console.error("usage: native vendor [dir] <package@exact-version> [more packages...]");
  process.exit(2);
}

function packageContentHash(root) {
  const files = [];
  const walk = (current, prefix = "") => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
      const absolute = path.join(current, entry.name);
      if (entry.isSymbolicLink()) throw new Error(`package contains a symlink: ${rel}`);
      if (entry.isDirectory()) walk(absolute, rel);
      else if (entry.isFile()) files.push({ rel, absolute });
    }
  };
  walk(root);
  files.sort((a, b) => a.rel < b.rel ? -1 : a.rel > b.rel ? 1 : 0);
  const hash = crypto.createHash("sha256");
  hash.update("native-sdk.service-package.v1\0");
  for (const file of files) {
    const bytes = fs.readFileSync(file.absolute);
    const size = Buffer.alloc(8);
    size.writeBigUInt64LE(BigInt(bytes.length));
    hash.update(file.rel);
    hash.update("\0");
    hash.update(size);
    hash.update(bytes);
  }
  return hash.digest("hex");
}

function packageDirectories(nodeModules) {
  const out = [];
  for (const entry of fs.readdirSync(nodeModules, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name === ".bin") continue;
    if (entry.name.startsWith("@")) {
      for (const child of fs.readdirSync(path.join(nodeModules, entry.name), { withFileTypes: true })) {
        if (child.isDirectory()) out.push(path.join(nodeModules, entry.name, child.name));
      }
    } else out.push(path.join(nodeModules, entry.name));
  }
  return out;
}

function replaceServicePackages(source, entries) {
  const rendered = [
    "    .service_packages = .{",
    ...entries.map((entry) => `        .{ .name = ${JSON.stringify(entry.name)}, .version = ${JSON.stringify(entry.version)}, .content_hash = ${JSON.stringify(entry.content_hash)} },`),
    "    },",
  ].join("\n");
  const marker = /(^|\n)[ \t]*\.service_packages[ \t]*=[ \t]*\.\{/m;
  const match = marker.exec(source);
  if (!match) {
    const close = source.lastIndexOf("}");
    if (close < 0) throw new Error("app.zon has no closing top-level brace");
    return `${source.slice(0, close).trimEnd()}\n${rendered}\n${source.slice(close)}`;
  }
  const fieldStart = match.index + match[1].length;
  let at = source.indexOf("{", fieldStart);
  let depth = 0;
  let string = false;
  let escaped = false;
  for (; at < source.length; at++) {
    const char = source[at];
    if (string) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === '"') string = false;
      continue;
    }
    if (char === '"') string = true;
    else if (char === "{") depth++;
    else if (char === "}" && --depth === 0) {
      let end = at + 1;
      while (/[ \t]/.test(source[end] ?? "")) end++;
      if (source[end] === ",") end++;
      return source.slice(0, fieldStart) + rendered + source.slice(end);
    }
  }
  throw new Error("app.zon service_packages field is not balanced");
}

const manifestPath = path.join(appRoot, "app.zon");
if (!fs.existsSync(manifestPath)) throw new Error(`${manifestPath} does not exist`);
const work = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-vendor-"));
try {
  const install = spawnSync("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund", "--package-lock=false", "--prefix", work, ...requested], { stdio: "inherit" });
  if (install.status !== 0) process.exit(install.status ?? 1);
  const nodeModules = path.join(work, "node_modules");
  const packages = packageDirectories(nodeModules);
  for (const packageDir of packages) {
    if (fs.existsSync(path.join(packageDir, "node_modules"))) {
      throw new Error("the resolved npm graph contains nested package versions; choose a dependency set npm can flatten before vendoring it for the static service tier");
    }
  }
  const vendorRoot = path.join(appRoot, "src", "services", "vendor");
  fs.mkdirSync(vendorRoot, { recursive: true });
  const entries = [];
  for (const packageDir of packages) {
    const manifest = JSON.parse(fs.readFileSync(path.join(packageDir, "package.json"), "utf8"));
    if (typeof manifest.name !== "string" || typeof manifest.version !== "string") throw new Error(`${packageDir} has no package identity`);
    const destination = path.join(vendorRoot, ...manifest.name.split("/"));
    fs.rmSync(destination, { recursive: true, force: true });
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.cpSync(packageDir, destination, { recursive: true });
    entries.push({ name: manifest.name, version: manifest.version, content_hash: packageContentHash(destination) });
  }
  entries.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
  const current = fs.readFileSync(manifestPath, "utf8");
  fs.writeFileSync(manifestPath, replaceServicePackages(current, entries));
  console.log(`vendored ${entries.length} package${entries.length === 1 ? "" : "s"} into src/services/vendor and updated app.zon`);
  for (const entry of entries) console.log(`  ${entry.name}@${entry.version} ${entry.content_hash}`);
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}

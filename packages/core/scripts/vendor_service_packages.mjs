#!/usr/bin/env node
// Resolve explicit npm versions only during `native vendor`, then copy every
// resolved package into the app-owned service vendor tree. Builds never run
// npm and accept these bytes only after verifying the manifest hash.

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

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

function servicePackagesField(source) {
  const marker = /(^|\n)[ \t]*\.service_packages[ \t]*=[ \t]*\.\{/m;
  const match = marker.exec(source);
  if (!match) return null;
  const fieldStart = match.index + match[1].length;
  const open = source.indexOf("{", fieldStart);
  let at = open;
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
      return { fieldStart, open, close: at, end };
    }
  }
  throw new Error("app.zon service_packages field is not balanced");
}

function parseJsonManifest(source) {
  const manifest = JSON.parse(source);
  if (manifest === null || Array.isArray(manifest) || typeof manifest !== "object") throw new Error("app.json must contain one object");
  return manifest;
}

function skipJsonWhitespace(source, start) {
  let at = start;
  while (/\s/.test(source[at] ?? "")) at++;
  return at;
}

function scanJsonString(source, start) {
  let escaped = false;
  for (let at = start + 1; at < source.length; at++) {
    const char = source[at];
    if (escaped) escaped = false;
    else if (char === "\\") escaped = true;
    else if (char === '"') return at + 1;
  }
  throw new Error("app.json contains an unterminated string");
}

function scanJsonValue(source, start) {
  const first = source[start];
  if (first === '"') return scanJsonString(source, start);
  if (first === "{" || first === "[") {
    const close = first === "{" ? "}" : "]";
    let depth = 1;
    let string = false;
    let escaped = false;
    for (let at = start + 1; at < source.length; at++) {
      const char = source[at];
      if (string) {
        if (escaped) escaped = false;
        else if (char === "\\") escaped = true;
        else if (char === '"') string = false;
        continue;
      }
      if (char === '"') string = true;
      else if (char === first) depth++;
      else if (char === close && --depth === 0) return at + 1;
    }
    throw new Error("app.json contains an unterminated value");
  }
  let at = start;
  while (at < source.length && !/[\s,}\]]/.test(source[at])) at++;
  return at;
}

function jsonObjectField(source, fieldName) {
  let at = skipJsonWhitespace(source, 0);
  if (source[at] !== "{") throw new Error("app.json must contain one object");
  at = skipJsonWhitespace(source, at + 1);
  let memberCount = 0;
  let match = null;
  while (source[at] !== "}") {
    if (source[at] !== '"') throw new Error("app.json contains an invalid object key");
    const keyStart = at;
    const keyEnd = scanJsonString(source, keyStart);
    const key = JSON.parse(source.slice(keyStart, keyEnd));
    at = skipJsonWhitespace(source, keyEnd);
    if (source[at] !== ":") throw new Error("app.json contains an invalid object field");
    const valueStart = skipJsonWhitespace(source, at + 1);
    const valueEnd = scanJsonValue(source, valueStart);
    memberCount++;
    if (key === fieldName) {
      if (match !== null) throw new Error(`app.json contains duplicate ${fieldName} fields`);
      match = { valueStart, valueEnd };
    }
    at = skipJsonWhitespace(source, valueEnd);
    if (source[at] === ",") at = skipJsonWhitespace(source, at + 1);
    else if (source[at] !== "}") throw new Error("app.json contains an invalid object separator");
  }
  return { match, close: at, memberCount };
}

function jsonTopLevelIndent(source, close) {
  const firstKey = source.indexOf('"', source.indexOf("{") + 1);
  const key = firstKey >= 0 && firstKey < close ? firstKey : close;
  const lineStart = source.lastIndexOf("\n", key - 1) + 1;
  const indent = source.slice(lineStart, key);
  return /^[ \t]+$/.test(indent) ? indent : "  ";
}

function renderJsonValue(value, indent) {
  return JSON.stringify(value, null, 2).replaceAll("\n", `\n${indent}`);
}

export function readServicePackages(source, format = "zon") {
  if (format === "json") {
    const entries = parseJsonManifest(source).service_packages ?? [];
    if (!Array.isArray(entries)) throw new Error("app.json service_packages must be an array");
    return entries.map((entry) => {
      if (entry === null || typeof entry !== "object" || typeof entry.name !== "string" || typeof entry.version !== "string" || typeof entry.content_hash !== "string") {
        throw new Error("app.json service_packages contains an invalid package fact");
      }
      return { name: entry.name, version: entry.version, content_hash: entry.content_hash };
    });
  }
  const field = servicePackagesField(source);
  if (!field) return [];
  const body = source.slice(field.open + 1, field.close);
  const entries = [];
  const pattern = /\.\{\s*\.name\s*=\s*("(?:\\.|[^"\\])*")\s*,\s*\.version\s*=\s*("(?:\\.|[^"\\])*")\s*,\s*\.content_hash\s*=\s*("(?:\\.|[^"\\])*")\s*,?\s*\}/g;
  for (const match of body.matchAll(pattern)) {
    const name = JSON.parse(match[1]);
    const version = JSON.parse(match[2]);
    const contentHash = JSON.parse(match[3]);
    if (typeof name !== "string" || typeof version !== "string" || typeof contentHash !== "string") {
      throw new Error("app.zon service_packages contains a non-string package fact");
    }
    entries.push({ name, version, content_hash: contentHash });
  }
  const declaredCount = body.match(/\.name\s*=/g)?.length ?? 0;
  if (entries.length !== declaredCount) throw new Error("app.zon service_packages is not in the package-fact shape written by native vendor");
  return entries;
}

function packageNameFromSpec(spec) {
  return spec.slice(0, spec.lastIndexOf("@"));
}

export function mergePackageSpecs(source, requested, format = "zon") {
  const specs = new Map(readServicePackages(source, format).map((entry) => [entry.name, `${entry.name}@${entry.version}`]));
  for (const spec of requested) specs.set(packageNameFromSpec(spec), spec);
  return [...specs].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([, spec]) => spec);
}

export function replaceServicePackages(source, entries, format = "zon") {
  if (format === "json") {
    parseJsonManifest(source);
    const field = jsonObjectField(source, "service_packages");
    const indent = jsonTopLevelIndent(source, field.close);
    const rendered = renderJsonValue(entries, indent);
    if (field.match) {
      return source.slice(0, field.match.valueStart) + rendered + source.slice(field.match.valueEnd);
    }
    const comma = field.memberCount === 0 ? "" : ",";
    return `${source.slice(0, field.close).trimEnd()}${comma}\n${indent}"service_packages": ${rendered}\n${source.slice(field.close)}`;
  }
  const rendered = [
    "    .service_packages = .{",
    ...entries.map((entry) => `        .{ .name = ${JSON.stringify(entry.name)}, .version = ${JSON.stringify(entry.version)}, .content_hash = ${JSON.stringify(entry.content_hash)} },`),
    "    },",
  ].join("\n");
  const field = servicePackagesField(source);
  if (!field) {
    const close = source.lastIndexOf("}");
    if (close < 0) throw new Error("app.zon has no closing top-level brace");
    return `${source.slice(0, close).trimEnd()}\n${rendered}\n${source.slice(close)}`;
  }
  return source.slice(0, field.fieldStart) + rendered + source.slice(field.end);
}

export function replaceVendorTree(vendorRoot, stageRoot) {
  fs.mkdirSync(path.dirname(vendorRoot), { recursive: true });
  fs.rmSync(vendorRoot, { recursive: true, force: true });
  fs.renameSync(stageRoot, vendorRoot);
}

function main(argv) {
  const appRoot = path.resolve(argv[2] ?? ".");
  const requested = argv.slice(3);
  if (requested.length === 0 || requested.some((spec) => !/^(?:@[a-z0-9._-]+\/)?[a-z0-9._-]+@\d+\.\d+\.\d+$/i.test(spec))) {
    console.error("usage: native vendor [dir] <package@exact-version> [more packages...]");
    return 2;
  }

  const jsonPath = path.join(appRoot, "app.json");
  const zonPath = path.join(appRoot, "app.zon");
  const manifestPath = fs.existsSync(jsonPath) ? jsonPath : zonPath;
  if (!fs.existsSync(manifestPath)) throw new Error(`${manifestPath} does not exist`);
  const format = manifestPath.endsWith(".json") ? "json" : "zon";
  const current = fs.readFileSync(manifestPath, "utf8");
  const installSpecs = mergePackageSpecs(current, requested, format);
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "native-service-vendor-"));
  const servicesRoot = path.join(appRoot, "src", "services");
  const stageRoot = path.join(appRoot, ".native", `.service-vendor-stage-${process.pid}-${Date.now()}`);
  try {
    const install = spawnSync("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund", "--package-lock=false", "--prefix", work, ...installSpecs], { stdio: "inherit" });
    if (install.status !== 0) return install.status ?? 1;
    const nodeModules = path.join(work, "node_modules");
    const packages = packageDirectories(nodeModules);
    for (const packageDir of packages) {
      if (fs.existsSync(path.join(packageDir, "node_modules"))) {
        throw new Error("the resolved npm graph contains nested package versions; choose a dependency set npm can flatten before vendoring it for the static service tier");
      }
    }
    fs.mkdirSync(stageRoot, { recursive: true });
    const entries = [];
    for (const packageDir of packages) {
      const manifest = JSON.parse(fs.readFileSync(path.join(packageDir, "package.json"), "utf8"));
      if (typeof manifest.name !== "string" || typeof manifest.version !== "string") throw new Error(`${packageDir} has no package identity`);
      const destination = path.join(stageRoot, ...manifest.name.split("/"));
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      fs.cpSync(packageDir, destination, { recursive: true });
      entries.push({ name: manifest.name, version: manifest.version, content_hash: packageContentHash(destination) });
    }
    entries.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
    const vendorRoot = path.join(servicesRoot, "vendor");
    replaceVendorTree(vendorRoot, stageRoot);
    fs.writeFileSync(manifestPath, replaceServicePackages(current, entries, format));
    console.log(`vendored ${entries.length} package${entries.length === 1 ? "" : "s"} into src/services/vendor and updated ${path.basename(manifestPath)}`);
    for (const entry of entries) console.log(`  ${entry.name}@${entry.version} ${entry.content_hash}`);
    return 0;
  } finally {
    fs.rmSync(stageRoot, { recursive: true, force: true });
    fs.rmSync(work, { recursive: true, force: true });
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main(process.argv);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}

#!/usr/bin/env node
// Stage the typed service executable: ordinary service TypeScript plus
// corewire's generated service_host_main.ts. One narrow mechanical lowering
// is required by scriptc 0.0.29: an escaping `throw { kind, message }` becomes
// an Error subclass carrying kind in `.name`, the object form its reachable
// static catch tier cannot inspect yet. NS1067 rejects locally caught tagged
// records; shared core-class modules receive the same transform in this
// scratch tree so a throw crossing the service boundary keeps its pair.

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import ts from "@typescript/old";

function argsOf(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 2) args[argv[i]?.replace(/^--/, "")] = argv[i + 1];
  for (const name of ["src", "host-main", "out"]) {
    if (!args[name]) {
      console.error("usage: stage_external_services.mjs --src <app src> --host-main <generated.ts> --out <stage>");
      process.exit(2);
    }
  }
  return args;
}

function unwrapExpression(expression) {
  while (ts.isAsExpression(expression) || ts.isTypeAssertionExpression(expression) || ts.isParenthesizedExpression(expression)) {
    expression = expression.expression;
  }
  return expression;
}

function taggedThrowParts(expression) {
  const value = unwrapExpression(expression);
  if (!ts.isObjectLiteralExpression(value) || value.properties.length !== 2) return null;
  const [kind, message] = value.properties;
  if (!ts.isPropertyAssignment(kind) || !ts.isIdentifier(kind.name) || kind.name.text !== "kind" || !ts.isStringLiteral(kind.initializer)) return null;
  if (!ts.isPropertyAssignment(message) || !ts.isIdentifier(message.name) || message.name.text !== "message") return null;
  return { kind: kind.initializer, message: message.initializer };
}

function lowerTaggedThrows(text, fileName) {
  const source = ts.createSourceFile(fileName, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const replacements = [];
  const visit = (node) => {
    if (ts.isThrowStatement(node) && node.expression) {
      const parts = taggedThrowParts(node.expression);
      if (parts) {
        replacements.push({
          start: node.expression.getStart(source),
          end: node.expression.end,
          text: `new __nativeSdkTaggedError(${parts.kind.getText(source)}, ${parts.message.getText(source)})`,
        });
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
  if (replacements.length === 0) return text;

  let insertAt = 0;
  for (const statement of source.statements) {
    if (!ts.isImportDeclaration(statement)) break;
    insertAt = statement.end;
  }
  replacements.push({
    start: insertAt,
    end: insertAt,
    text: `${insertAt === 0 ? "" : "\n"}\nclass __nativeSdkTaggedError extends Error {\n  readonly kind: string;\n\n  constructor(kind: string, message: unknown) {\n    super(String(message));\n    this.kind = kind;\n    this.name = kind;\n  }\n}\n`,
  });
  replacements.sort((a, b) => b.start - a.start);
  for (const replacement of replacements) {
    text = text.slice(0, replacement.start) + replacement.text + text.slice(replacement.end);
  }
  return text;
}

function serviceCapabilityImport(text, rel) {
  const target = path.posix.relative(path.posix.dirname(rel), "__native_sdk_service_types.ts");
  const specifier = target.startsWith(".") ? target : `./${target}`;
  return text.replace(/(from\s+["'])@native-sdk\/core(["'])/g, `$1${specifier}$2`);
}

function copyTsTree(from, to, sub = "") {
  for (const entry of fs.readdirSync(path.join(from, sub), { withFileTypes: true })) {
    const rel = sub ? `${sub}/${entry.name}` : entry.name;
    if (entry.isDirectory() && rel !== "services/vendor") copyTsTree(from, to, rel);
    else if (entry.isFile() && entry.name.endsWith(".ts") && !entry.name.endsWith(".d.ts")) {
      const destination = path.join(to, rel);
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      const source = fs.readFileSync(path.join(from, rel), "utf8");
      fs.writeFileSync(destination, lowerTaggedThrows(serviceCapabilityImport(source, rel), rel));
    }
  }
}

function packagePath(root, name) {
  if (!/^(?:@[a-z0-9._-]+\/)?[a-z0-9._-]+$/i.test(name)) {
    throw new Error(`service package name ${JSON.stringify(name)} is not a safe npm package name`);
  }
  return path.join(root, ...name.split("/"));
}

function packageContentHash(root) {
  const files = [];
  const walk = (current, prefix = "") => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
      const absolute = path.join(current, entry.name);
      if (entry.isSymbolicLink()) throw new Error(`vendored package contains a symlink: ${rel}`);
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

function stagePackages(src, out, contractPath) {
  if (!contractPath) return;
  const contract = JSON.parse(fs.readFileSync(contractPath, "utf8"));
  const packages = contract.packages ?? [];
  const vendorRoot = path.join(src, "services", "vendor");
  for (const packageEntry of packages) {
    const source = packagePath(vendorRoot, packageEntry.name);
    if (!fs.statSync(source, { throwIfNoEntry: false })?.isDirectory()) {
      throw new Error(`service package ${packageEntry.name}@${packageEntry.version} is not checked in at ${source}`);
    }
    const packageJson = JSON.parse(fs.readFileSync(path.join(source, "package.json"), "utf8"));
    if (packageJson.name !== packageEntry.name || packageJson.version !== packageEntry.version) {
      throw new Error(`vendored ${packageEntry.name} identifies itself as ${packageJson.name ?? "?"}@${packageJson.version ?? "?"}, expected ${packageEntry.name}@${packageEntry.version}`);
    }
    const actual = packageContentHash(source);
    if (actual !== packageEntry.content_hash) {
      throw new Error(`vendored ${packageEntry.name}@${packageEntry.version} hashes to ${actual}, expected ${packageEntry.content_hash}; re-run native vendor or restore the checked-in package bytes`);
    }
    const destination = packagePath(path.join(out, "node_modules"), packageEntry.name);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.cpSync(source, destination, { recursive: true, errorOnExist: true, force: false });
  }
}

const args = argsOf(process.argv);
fs.rmSync(args.out, { recursive: true, force: true });
fs.mkdirSync(args.out, { recursive: true });
copyTsTree(args.src, args.out);
fs.writeFileSync(path.join(args.out, "__native_sdk_service_types.ts"), `
export interface ServiceCancellation {
  readonly cancelled: () => boolean;
  readonly throwIfCancelled: () => void;
}
`);
stagePackages(args.src, args.out, args.contract);
fs.copyFileSync(args["host-main"], path.join(args.out, "service_host_main.ts"));
// The in-process carrier's library entry and its compiler profile stage
// beside the child host main; the archive compile resolves the profile's
// entry relative to the profile file, so both land at the stage root.
if (args["inproc-main"]) fs.copyFileSync(args["inproc-main"], path.join(args.out, "service_inproc_main.ts"));
if (args["inproc-profile"]) fs.copyFileSync(args["inproc-profile"], path.join(args.out, "service_profile.json"));

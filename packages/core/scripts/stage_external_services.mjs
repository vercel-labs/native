#!/usr/bin/env node
// Stage the phase-1 service executable: ordinary service TypeScript plus
// corewire's generated service_host_main.ts. One narrow mechanical lowering
// is required by scriptc 0.0.22: an escaping `throw { kind, message }` becomes
// an Error subclass carrying kind in `.name`, the object form its reachable
// static catch tier cannot inspect yet. NS1067 rejects locally caught tagged
// records; shared core-class modules receive the same transform in this
// scratch tree so a throw crossing the service boundary keeps its pair.

import fs from "node:fs";
import path from "node:path";
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

function copyTsTree(from, to, sub = "") {
  for (const entry of fs.readdirSync(path.join(from, sub), { withFileTypes: true })) {
    const rel = sub ? `${sub}/${entry.name}` : entry.name;
    if (entry.isDirectory()) copyTsTree(from, to, rel);
    else if (entry.isFile() && entry.name.endsWith(".ts") && !entry.name.endsWith(".d.ts")) {
      const destination = path.join(to, rel);
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      const source = fs.readFileSync(path.join(from, rel), "utf8");
      fs.writeFileSync(destination, lowerTaggedThrows(source, rel));
    }
  }
}

const args = argsOf(process.argv);
fs.rmSync(args.out, { recursive: true, force: true });
fs.mkdirSync(args.out, { recursive: true });
copyTsTree(args.src, args.out);
fs.copyFileSync(args["host-main"], path.join(args.out, "service_host_main.ts"));

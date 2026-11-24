// Checks the CLI's own sources for the constructs scriptc 0.4.14 refuses to compile, so a change
// that only fails when the executable is built on five platforms fails here first, in a second.
//
// The CLI is compiled by scriptc (scripts/build-native.ts), and scriptc reads some options at
// compile time. It reports, for example, "spawnSync with a non-literal options argument" (SC2020)
// and a conditional spread in a call's object (SC1090). This walks the file set the executable is
// built from and fails on those forms.
//   node scripts/check-scriptc-forms.ts

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import * as ts from "typescript";

const ROOT = new URL("..", import.meta.url).pathname;

/** The child-process calls whose options object scriptc reads at compile time. */
const SPAWN_CALLS = new Set(["spawn", "spawnSync", "spawnSyncWithBuffer", "execFile", "execFileSync"]);

const problems: string[] = [];

function scan(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) out.push(...scan(full));
    else if (/\.(?:ts|mts)$/.test(full) && !/\.d\.ts$/.test(full)) out.push(full);
  }
  return out;
}

/** The options argument of a spawn call: the last one, when it is not an array literal. */
function optionsArgument(call: ts.CallExpression): ts.Expression | null {
  const args = call.arguments;
  const last = args[args.length - 1];
  if (last === undefined || args.length < 2) return null;
  if (ts.isArrayLiteralExpression(last)) return null;
  return last;
}

/** A parenthesised expression's inner expression, however deeply parenthesised. */
function unparen(node: ts.Expression): ts.Expression {
  let current = node;
  while (ts.isParenthesizedExpression(current)) current = current.expression;
  return current;
}

/** Whether a value is a form scriptc reads at compile time: a string or an array literal. */
function isLiteralValue(node: ts.Expression): boolean {
  const value = unparen(node);
  if (ts.isStringLiteral(value) || ts.isArrayLiteralExpression(value)) return true;
  return ts.isIdentifier(value) && (value.text === "undefined" || value.text === "null");
}

for (const file of [...scan(join(ROOT, "compiler")), ...scan(join(ROOT, "runtime")), ...scan(join(ROOT, "scripts"))]) {
  const text = readFileSync(file, "utf8");
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const report = (node: ts.Node, message: string): void => {
    const at = source.getLineAndCharacterOfPosition(node.getStart(source));
    problems.push(`${relative(ROOT, file)}:${at.line + 1}:${at.character + 1} ${message}`);
  };
  const visit = (node: ts.Node): void => {
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && SPAWN_CALLS.has(node.expression.text)) {
      const options = optionsArgument(node);
      if (options !== null && !ts.isObjectLiteralExpression(options)) {
        report(options, `${node.expression.text}() takes its options from a variable; scriptc needs a literal here (SC2020)`);
      }
      if (options !== null && ts.isObjectLiteralExpression(options)) {
        for (const property of options.properties) {
          if (!ts.isPropertyAssignment(property)) continue;
          const name = property.name.getText(source);
          if (name === "stdio" && !isLiteralValue(property.initializer)) {
            report(property, "spawn()'s stdio is not a literal; scriptc reads it at compile time (SC2020)");
          }
        }
      }
    }
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === "watch") {
      const options = node.arguments[1];
      if (options !== undefined && ts.isObjectLiteralExpression(options)) {
        for (const property of options.properties) {
          if (ts.isPropertyAssignment(property) && property.name.getText(source) === "recursive") {
            report(property, "fs.watch with the recursive option has no scriptc lowering; use watchTree() (SC2020)");
          }
        }
      }
    }
    if (ts.isObjectLiteralExpression(node)) {
      for (const property of node.properties) {
        if (ts.isSpreadAssignment(property) && ts.isConditionalExpression(unparen(property.expression))) {
          report(property, "an object spread of a conditional; assign the fields instead (SC1090)");
        }
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
}

if (problems.length > 0) {
  console.error("The CLI's sources use constructs scriptc cannot compile:");
  for (const problem of problems) console.error("  " + problem);
  process.exit(1);
}
console.log("ok   the CLI's sources use only the forms scriptc compiles");

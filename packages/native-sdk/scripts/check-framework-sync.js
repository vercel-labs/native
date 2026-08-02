#!/usr/bin/env node

import { existsSync, lstatSync, readdirSync, readFileSync, readlinkSync } from 'fs';
import { dirname, join, relative, sep } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, '..');
const repoRoot = join(projectRoot, '..', '..');

const mirrors = [
  { source: 'src', target: 'src' },
  { source: 'build', target: 'build' },
  { source: 'assets', target: 'assets' },
  { source: 'build.zig', target: 'build.zig' },
  { source: 'build.zig.zon', target: 'build.zig.zon' },
  { source: 'app.zon', target: 'app.zon' },
  { source: 'LICENSE', target: 'LICENSE' },
  { source: 'skills', target: 'skills' },
  { source: 'skill-data', target: 'skill-data' },
  { source: 'third_party/webview2', target: 'third_party/webview2' },
  // The @native-sdk/core closure TypeScript app builds resolve from the
  // installed package: the transpiler, the SDK library modules (also the
  // editor package), the rt kernel, and the manifest + lockfile that make
  // `npm ci` work inside packages/core on the npm-installed layout.
  // Entry-by-entry on purpose — test/ and scripts/ are repo-dev surface
  // and must NOT ship, so the whole-directory comparison stays off.
  { source: 'packages/core/src', target: 'packages/core/src' },
  { source: 'packages/core/sdk', target: 'packages/core/sdk' },
  { source: 'packages/core/rt', target: 'packages/core/rt' },
  { source: 'packages/core/package.json', target: 'packages/core/package.json' },
  { source: 'packages/core/package-lock.json', target: 'packages/core/package-lock.json' },
];

const errors = [];

function displayPath(path) {
  return relative(repoRoot, path).split(sep).join('/');
}

function addError(message) {
  errors.push(message);
}

function compareEntries(sourcePath, targetPath) {
  if (!existsSync(sourcePath)) {
    addError(`missing source ${displayPath(sourcePath)}`);
    return;
  }
  if (!existsSync(targetPath)) {
    addError(`missing mirror ${displayPath(targetPath)}`);
    return;
  }

  const sourceStat = lstatSync(sourcePath);
  const targetStat = lstatSync(targetPath);

  if (sourceStat.isSymbolicLink() || targetStat.isSymbolicLink()) {
    if (!sourceStat.isSymbolicLink() || !targetStat.isSymbolicLink()) {
      addError(`type mismatch ${displayPath(sourcePath)} -> ${displayPath(targetPath)}`);
      return;
    }
    const sourceLink = readlinkSync(sourcePath);
    const targetLink = readlinkSync(targetPath);
    if (sourceLink !== targetLink) {
      addError(`symlink mismatch ${displayPath(sourcePath)} -> ${displayPath(targetPath)}`);
    }
    return;
  }

  if (sourceStat.isDirectory() || targetStat.isDirectory()) {
    if (!sourceStat.isDirectory() || !targetStat.isDirectory()) {
      addError(`type mismatch ${displayPath(sourcePath)} -> ${displayPath(targetPath)}`);
      return;
    }
    const sourceNames = readdirSync(sourcePath).filter((name) => name !== '.DS_Store').sort();
    const targetNames = readdirSync(targetPath).filter((name) => name !== '.DS_Store').sort();
    const names = new Set([...sourceNames, ...targetNames]);
    for (const name of names) {
      compareEntries(join(sourcePath, name), join(targetPath, name));
    }
    return;
  }

  if (!sourceStat.isFile() || !targetStat.isFile()) {
    addError(`unsupported entry type ${displayPath(sourcePath)} -> ${displayPath(targetPath)}`);
    return;
  }

  const sourceBytes = readFileSync(sourcePath);
  const targetBytes = readFileSync(targetPath);
  if (!sourceBytes.equals(targetBytes)) {
    addError(`content mismatch ${displayPath(sourcePath)} -> ${displayPath(targetPath)}`);
  }
}

for (const mirror of mirrors) {
  compareEntries(join(repoRoot, mirror.source), join(projectRoot, mirror.target));
}

// Every file build/app.zig resolves from the installed package via
// dep.path must actually ship with the package: it has to exist in the
// staged mirror and sit under an entry of package.json "files", or every
// generated app build fails on a missing input after install. Literals
// reach dep.path directly, through the externalModule helper, and through
// an inline switch, so collect all three forms.
function collectDepPathLiterals(source) {
  const literals = new Set();
  for (const match of source.matchAll(/dep\.path\(\s*"([^"]+)"\s*\)/g)) {
    literals.add(match[1]);
  }
  for (const match of source.matchAll(/externalModule\(\s*b\s*,\s*dep\s*,[^)]*?"([^"]+)"\s*\)/g)) {
    literals.add(match[1]);
  }
  for (const match of source.matchAll(/dep\.path\(\s*switch\s*\([^)]*\)\s*\{([^}]*)\}/g)) {
    for (const literal of match[1].matchAll(/"([^"]+)"/g)) {
      literals.add(literal[1]);
    }
  }
  return [...literals].sort();
}

const appZigPath = join(repoRoot, 'build', 'app.zig');
const packageFiles = JSON.parse(readFileSync(join(projectRoot, 'package.json'), 'utf8')).files ?? [];

function coveredByFiles(literal) {
  return packageFiles.some((entry) => literal === entry || literal.startsWith(`${entry}/`));
}

for (const literal of collectDepPathLiterals(readFileSync(appZigPath, 'utf8'))) {
  if (!existsSync(join(projectRoot, literal))) {
    addError(`build/app.zig dep.path("${literal}") is missing from the package mirror`);
  }
  if (!coveredByFiles(literal)) {
    addError(`build/app.zig dep.path("${literal}") is not covered by package.json "files"`);
  }
}

if (errors.length > 0) {
  console.error('Package framework mirror is out of sync.');
  for (const error of errors.slice(0, 20)) {
    console.error(`  - ${error}`);
  }
  if (errors.length > 20) {
    console.error(`  ... ${errors.length - 20} more`);
  }
  console.error('');
  console.error('The package mirror is GENERATED output: copy-framework.js stages it');
  console.error('from the repo-root framework sources (prepack and scripts:check run');
  console.error('the copy first), and the mirror paths are gitignored — committing the');
  console.error('mirror is not the fix. Regenerate it, then re-run this check:');
  console.error('');
  console.error('  node packages/native-sdk/scripts/copy-framework.js   (from the repo root)');
  process.exit(1);
}

console.log('Package framework mirror is in sync.');

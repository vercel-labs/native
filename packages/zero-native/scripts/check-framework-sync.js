#!/usr/bin/env node

import { existsSync, lstatSync, readdirSync, readFileSync, readlinkSync } from 'fs';
import { dirname, join, relative, sep } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, '..');
const repoRoot = join(projectRoot, '..', '..');

const mirrors = [
  { source: 'src', target: 'src' },
  { source: 'skills', target: 'skills' },
  { source: 'skill-data', target: 'skill-data' },
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

if (errors.length > 0) {
  console.error('Package framework mirror is out of sync.');
  for (const error of errors.slice(0, 20)) {
    console.error(`  - ${error}`);
  }
  if (errors.length > 20) {
    console.error(`  ... ${errors.length - 20} more`);
  }
  console.error('\nRun "node packages/zero-native/scripts/copy-framework.js" from the repo root.');
  process.exit(1);
}

console.log('Package framework mirror is in sync.');

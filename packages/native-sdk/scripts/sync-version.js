#!/usr/bin/env node

// One version number rules them all: packages/native-sdk/package.json is
// the source of truth, and this script stamps it into the CLI source
// (tools/native-sdk/main.zig), every per-platform binary package under
// npm/, and the main package's own optionalDependencies pins. The pins
// are exact so a given @native-sdk/cli always installs the binary built
// from the same commit. The same pass propagates the repo identity
// fields (repository and homepage) into each platform package, so a
// repository rename or domain move applied to the main package cannot
// leave the platform packages behind and fail publish provenance checks.
//
// packages/core (@native-sdk/core) rides the same release version: its
// manifest and lockfile get the CLI version, so the version every TS
// scaffold pins (templates read the bundled manifest) and the editor copy
// the CLI materializes match the npm publish the moment the package goes
// public. The committed TS examples pin the bundled version by hand, so
// they are stamped here too (tests/ts-core/scaffold_ide_e2e_tests.zig
// fails the build when an example pin drifts from the bundled version).

import { readdirSync, readFileSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, '..');
const repoRoot = join(projectRoot, '..', '..');

const packageJsonPath = join(projectRoot, 'package.json');
const packageJson = JSON.parse(readFileSync(packageJsonPath, 'utf-8'));
const version = packageJson.version;

console.log(`Syncing version ${version}...`);

// tools/native-sdk/main.zig
const mainZigPath = join(repoRoot, 'tools', 'native-sdk', 'main.zig');
let mainZig = readFileSync(mainZigPath, 'utf-8');

const versionPattern = /^const version = "[^"]*";/m;
const match = mainZig.match(versionPattern);

if (!match) {
  console.error('  Could not find `const version = "...";` in tools/native-sdk/main.zig');
  process.exit(1);
}

const newVersionLine = `const version = "${version}";`;

if (match[0] !== newVersionLine) {
  mainZig = mainZig.replace(versionPattern, newVersionLine);
  writeFileSync(mainZigPath, mainZig);
  console.log(`  Updated tools/native-sdk/main.zig: ${match[0]} -> ${newVersionLine}`);
} else {
  console.log(`  tools/native-sdk/main.zig already up to date`);
}

// npm/<platform>/package.json
const npmDir = join(projectRoot, 'npm');
for (const entry of readdirSync(npmDir, { withFileTypes: true })) {
  if (!entry.isDirectory()) continue;
  const platformJsonPath = join(npmDir, entry.name, 'package.json');
  const platformJson = JSON.parse(readFileSync(platformJsonPath, 'utf-8'));
  let changed = false;
  if (platformJson.version !== version) {
    platformJson.version = version;
    changed = true;
  }
  if (platformJson.repository?.url !== packageJson.repository?.url) {
    platformJson.repository = { ...packageJson.repository };
    changed = true;
  }
  if (platformJson.homepage !== packageJson.homepage) {
    platformJson.homepage = packageJson.homepage;
    changed = true;
  }
  if (changed) {
    writeFileSync(platformJsonPath, JSON.stringify(platformJson, null, 2) + '\n');
    console.log(`  Updated npm/${entry.name}/package.json`);
  } else {
    console.log(`  npm/${entry.name}/package.json already up to date`);
  }
}

// packages/core: the bundled @native-sdk/core manifest and its lockfile's
// own-package version fields (npm ci reads the lock; the dependency
// entries under node_modules/* are not ours to stamp).
{
  const corePackageJsonPath = join(repoRoot, 'packages', 'core', 'package.json');
  const coreJson = JSON.parse(readFileSync(corePackageJsonPath, 'utf-8'));
  if (coreJson.version !== version) {
    coreJson.version = version;
    writeFileSync(corePackageJsonPath, JSON.stringify(coreJson, null, 2) + '\n');
    console.log(`  Updated packages/core/package.json`);
  } else {
    console.log(`  packages/core/package.json already up to date`);
  }

  const coreLockPath = join(repoRoot, 'packages', 'core', 'package-lock.json');
  const coreLock = JSON.parse(readFileSync(coreLockPath, 'utf-8'));
  let lockChanged = false;
  if (coreLock.version !== version) {
    coreLock.version = version;
    lockChanged = true;
  }
  if (coreLock.packages?.['']?.version !== version) {
    coreLock.packages[''].version = version;
    lockChanged = true;
  }
  if (lockChanged) {
    writeFileSync(coreLockPath, JSON.stringify(coreLock, null, 2) + '\n');
    console.log(`  Updated packages/core/package-lock.json`);
  } else {
    console.log(`  packages/core/package-lock.json already up to date`);
  }
}

// The committed TS examples' @native-sdk/core pins (exact, like the
// scaffold's, so a post-publish `npm install` resolves the same content
// the CLI materializes).
for (const example of ['examples/soundboard-ts', 'examples/system-monitor-ts']) {
  const examplePath = join(repoRoot, ...example.split('/'), 'package.json');
  const exampleJson = JSON.parse(readFileSync(examplePath, 'utf-8'));
  if (exampleJson.dependencies?.['@native-sdk/core'] !== version) {
    exampleJson.dependencies['@native-sdk/core'] = version;
    writeFileSync(examplePath, JSON.stringify(exampleJson, null, 2) + '\n');
    console.log(`  Updated ${example}/package.json`);
  } else {
    console.log(`  ${example}/package.json already up to date`);
  }
}

// The main package's optionalDependencies pins.
let pinsChanged = false;
for (const name of Object.keys(packageJson.optionalDependencies ?? {})) {
  if (packageJson.optionalDependencies[name] !== version) {
    packageJson.optionalDependencies[name] = version;
    pinsChanged = true;
  }
}
if (pinsChanged) {
  writeFileSync(packageJsonPath, JSON.stringify(packageJson, null, 2) + '\n');
  console.log('  Updated optionalDependencies pins in package.json');
} else {
  console.log('  optionalDependencies pins already up to date');
}

console.log('Version sync complete.');

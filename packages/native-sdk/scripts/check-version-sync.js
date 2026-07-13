#!/usr/bin/env node

// Verify every version stamped by sync-version.js matches
// packages/native-sdk/package.json: the CLI source, the per-platform
// binary packages, the bundled @native-sdk/core (manifest + lockfile,
// the version every TS scaffold and example pin follows), and the
// optionalDependencies pins. Also verify each
// platform package's repository.url and homepage match the main package,
// because npm validates repository.url against publish provenance and a
// repository rename that only updates the main package fails the publish.
// CI runs this before publish so a half-bumped release cannot ship.

import { readdirSync, readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, '..');
const repoRoot = join(projectRoot, '..', '..');

const packageJson = JSON.parse(readFileSync(join(projectRoot, 'package.json'), 'utf-8'));
const expectedVersion = packageJson.version;

let errors = 0;

const mainZigPath = join(repoRoot, 'tools', 'native-sdk', 'main.zig');
const mainZig = readFileSync(mainZigPath, 'utf-8');

const versionMatch = mainZig.match(/^const version = "([^"]*)";/m);

if (!versionMatch) {
  console.error('Could not find `const version = "...";` in tools/native-sdk/main.zig');
  process.exit(1);
}

if (versionMatch[1] !== expectedVersion) {
  console.error(`Version mismatch: package.json=${expectedVersion}, tools/native-sdk/main.zig=${versionMatch[1]}`);
  errors++;
}

const npmDir = join(projectRoot, 'npm');
for (const entry of readdirSync(npmDir, { withFileTypes: true })) {
  if (!entry.isDirectory()) continue;
  const platformJson = JSON.parse(readFileSync(join(npmDir, entry.name, 'package.json'), 'utf-8'));
  if (platformJson.version !== expectedVersion) {
    console.error(`Version mismatch: package.json=${expectedVersion}, npm/${entry.name}/package.json=${platformJson.version}`);
    errors++;
  }
  const expectedName = `@native-sdk/cli-${entry.name}`;
  if (platformJson.name !== expectedName) {
    console.error(`Name mismatch: npm/${entry.name}/package.json is ${platformJson.name}, expected ${expectedName}`);
    errors++;
  }
  if (!(expectedName in (packageJson.optionalDependencies ?? {}))) {
    console.error(`Missing optionalDependencies pin for ${expectedName} in package.json`);
    errors++;
  }
  const expectedRepositoryUrl = packageJson.repository?.url;
  if (platformJson.repository?.url !== expectedRepositoryUrl) {
    console.error(`Repository mismatch: npm/${entry.name}/package.json repository.url is ${platformJson.repository?.url}, expected ${expectedRepositoryUrl} from package.json`);
    errors++;
  }
  if (platformJson.homepage !== packageJson.homepage) {
    console.error(`Homepage mismatch: npm/${entry.name}/package.json homepage is ${platformJson.homepage}, expected ${packageJson.homepage} from package.json`);
    errors++;
  }
}

for (const [name, pin] of Object.entries(packageJson.optionalDependencies ?? {})) {
  if (pin !== expectedVersion) {
    console.error(`Version mismatch: optionalDependencies["${name}"]=${pin}, expected ${expectedVersion}`);
    errors++;
  }
}

// The bundled @native-sdk/core rides the release version (manifest and
// lockfile own-package fields), and the committed TS examples pin it
// exactly — half-bumped, a published CLI would scaffold pins npm cannot
// resolve to the matching @native-sdk/core release.
const coreJson = JSON.parse(readFileSync(join(repoRoot, 'packages', 'core', 'package.json'), 'utf-8'));
if (coreJson.version !== expectedVersion) {
  console.error(`Version mismatch: packages/core/package.json=${coreJson.version}, expected ${expectedVersion}`);
  errors++;
}
// npm validates repository.url against publish provenance for
// @native-sdk/core exactly as it does for the platform packages — a
// missing or renamed URL fails the publish, so pin it to the main package.
if (coreJson.repository?.url !== packageJson.repository?.url) {
  console.error(`Repository mismatch: packages/core/package.json repository.url is ${coreJson.repository?.url}, expected ${packageJson.repository?.url} from package.json`);
  errors++;
}
if (coreJson.homepage !== packageJson.homepage) {
  console.error(`Homepage mismatch: packages/core/package.json homepage is ${coreJson.homepage}, expected ${packageJson.homepage} from package.json`);
  errors++;
}
// The CLI carries the transpiler's TypeScript toolchain as a REGULAR
// dependency: npm installs @typescript/typescript6 in the same transaction
// as @native-sdk/cli, so the bundled packages/core resolves it through
// node's ancestor node_modules walk with no install step at verb time
// (offline, read-only-prefix, and production-config safe). Both pins must
// be the SAME EXACT version (no ranges): every transpiler test and the
// hardcoded lib/typescript.js entrypoint run against one toolchain
// version, and a range would let a fresh CLI install resolve a different
// 6.x than the one packages/core develops against — toolchain drift must
// be a deliberate event (bump both manifests and the lockfile together).
const coreTsPin = coreJson.devDependencies?.['@typescript/typescript6'];
const cliTsPin = packageJson.dependencies?.['@typescript/typescript6'];
if (!coreTsPin) {
  console.error('packages/core/package.json is missing the @typescript/typescript6 devDependency');
  errors++;
} else if (!/^\d+\.\d+\.\d+$/.test(coreTsPin)) {
  console.error(`packages/core/package.json devDependencies["@typescript/typescript6"]=${coreTsPin} is a range, not an exact version pin`);
  errors++;
}
if (cliTsPin !== coreTsPin) {
  console.error(`Pin mismatch: package.json dependencies["@typescript/typescript6"]=${cliTsPin}, expected ${coreTsPin} from packages/core devDependencies`);
  errors++;
}
// @typescript/typescript6 is only a WRAPPER: its lib/typescript.js
// re-exports "@typescript/old", an npm ALIAS whose own dependency range is
// a CARET (npm:typescript@^6). Pinning the wrapper alone therefore pins
// nothing about the compiler that actually runs — published packages carry
// no lockfile, so a consumer install would resolve whatever typescript ^6
// the registry serves that day. Both manifests must also pin the alias
// directly (a top-level entry npm dedupes the wrapper's transitive
// dependency onto), in the exact `npm:typescript@X.Y.Z` form — a range
// after the @ reopens the same drift the wrapper pin closes.
const aliasPinShape = /^npm:typescript@\d+\.\d+\.\d+$/;
const coreAliasPin = coreJson.devDependencies?.['@typescript/old'];
const cliAliasPin = packageJson.dependencies?.['@typescript/old'];
if (!coreAliasPin) {
  console.error('packages/core/package.json is missing the @typescript/old devDependency (the exact alias pin for the real compiler behind the @typescript/typescript6 wrapper)');
  errors++;
} else if (!aliasPinShape.test(coreAliasPin)) {
  console.error(`packages/core/package.json devDependencies["@typescript/old"]=${coreAliasPin} is not an exact npm:typescript@X.Y.Z alias pin (ranges after the @ let consumer installs drift)`);
  errors++;
}
if (cliAliasPin !== coreAliasPin) {
  console.error(`Pin mismatch: package.json dependencies["@typescript/old"]=${cliAliasPin}, expected ${coreAliasPin} from packages/core devDependencies`);
  errors++;
}
const coreLock = JSON.parse(readFileSync(join(repoRoot, 'packages', 'core', 'package-lock.json'), 'utf-8'));
if (coreLock.version !== expectedVersion || coreLock.packages?.['']?.version !== expectedVersion) {
  console.error(`Version mismatch: packages/core/package-lock.json=${coreLock.version}/${coreLock.packages?.['']?.version}, expected ${expectedVersion}`);
  errors++;
}
for (const example of ['examples/soundboard-ts', 'examples/system-monitor-ts']) {
  const exampleJson = JSON.parse(readFileSync(join(repoRoot, ...example.split('/'), 'package.json'), 'utf-8'));
  const pin = exampleJson.dependencies?.['@native-sdk/core'];
  if (pin !== expectedVersion) {
    console.error(`Version mismatch: ${example}/package.json pins @native-sdk/core ${pin}, expected ${expectedVersion}`);
    errors++;
  }
}

if (errors > 0) {
  console.error(`\nRun "npm run version:sync" in packages/native-sdk to fix.`);
  process.exit(1);
}

console.log(`Versions in sync: ${expectedVersion}`);

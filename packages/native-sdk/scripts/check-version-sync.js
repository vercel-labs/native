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

import { existsSync, readdirSync, readFileSync } from 'fs';
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
// The CLI carries the frontend's TypeScript compiler as a REGULAR
// dependency via the @typescript/old ALIAS (npm:typescript@X.Y.Z): npm
// installs it in the same transaction as @native-sdk/cli, so the bundled
// packages/core resolves it through node's ancestor node_modules walk
// with no install step at verb time (offline, read-only-prefix, and
// production-config safe). Both manifests must pin the alias in the
// exact `npm:typescript@X.Y.Z` form — a range after the @ would let a
// fresh CLI install resolve a different version than the one
// packages/core develops against; toolchain drift must be a deliberate
// event (bump both manifests and the lockfile together).
const aliasPinShape = /^npm:typescript@\d+\.\d+\.\d+$/;
const coreAliasPin = coreJson.devDependencies?.['@typescript/old'];
const cliAliasPin = packageJson.dependencies?.['@typescript/old'];
if (!coreAliasPin) {
  console.error('packages/core/package.json is missing the @typescript/old devDependency (the exact npm:typescript alias pin for the frontend compiler)');
  errors++;
} else if (!aliasPinShape.test(coreAliasPin)) {
  console.error(`packages/core/package.json devDependencies["@typescript/old"]=${coreAliasPin} is not an exact npm:typescript@X.Y.Z alias pin (ranges after the @ let consumer installs drift)`);
  errors++;
}
if (cliAliasPin !== coreAliasPin) {
  console.error(`Pin mismatch: package.json dependencies["@typescript/old"]=${cliAliasPin}, expected ${coreAliasPin} from packages/core devDependencies`);
  errors++;
}
// The external core compiler rides the same way: a REGULAR dependency of
// the CLI so npm installs it in the same transaction, resolved from
// packages/core by node's ancestor walk. The profile's determinism-fence
// tables are release-pinned data, so both manifests must carry one EXACT
// pin (packages/core's dependencies entry is the authority).
const coreCompilerPin = coreJson.dependencies?.scriptc;
const cliCompilerPin = packageJson.dependencies?.scriptc;
if (!coreCompilerPin) {
  console.error('packages/core/package.json is missing the exact external core compiler pin in dependencies');
  errors++;
} else if (!/^\d+\.\d+\.\d+$/.test(coreCompilerPin)) {
  console.error(`packages/core/package.json dependencies pin ${coreCompilerPin} is a range, not an exact version pin`);
  errors++;
}
if (cliCompilerPin !== coreCompilerPin) {
  console.error(`Pin mismatch: package.json carries external core compiler pin ${cliCompilerPin}, expected ${coreCompilerPin} from packages/core dependencies`);
  errors++;
}
const coreLock = JSON.parse(readFileSync(join(repoRoot, 'packages', 'core', 'package-lock.json'), 'utf-8'));
if (coreLock.version !== expectedVersion || coreLock.packages?.['']?.version !== expectedVersion) {
  console.error(`Version mismatch: packages/core/package-lock.json=${coreLock.version}/${coreLock.packages?.['']?.version}, expected ${expectedVersion}`);
  errors++;
}
const examplesDir = join(repoRoot, 'examples');
for (const entry of readdirSync(examplesDir, { withFileTypes: true })) {
  if (!entry.isDirectory()) continue;
  const example = `examples/${entry.name}`;
  const examplePath = join(examplesDir, entry.name, 'package.json');
  if (!existsSync(examplePath)) continue;
  const exampleJson = JSON.parse(readFileSync(examplePath, 'utf-8'));
  const pin = exampleJson.dependencies?.['@native-sdk/core'];
  if (!pin) continue;
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

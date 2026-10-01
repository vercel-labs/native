// Invoked through build/ts_run.mjs so installed node_modules layouts use the
// same pinned TS loader. Tests resolve the build's SDK, like core compilation.
import { registerHooks } from 'node:module';
import { readdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [host, directory] = process.argv.slice(2);
if (!host || !directory) throw new Error('usage: run_native_tests.mjs <host> <tests-directory>');
process.env.NATIVE_SDK_TEST_HOST = resolve(host);
const testingUrl = new URL('../testing/index.ts', import.meta.url).href;
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === '@native-sdk/core/testing') return { url: testingUrl, shortCircuit: true };
    return nextResolve(specifier, context);
  },
});
const tests = readdirSync(directory, { withFileTypes: true })
  .filter(entry => entry.isFile() && entry.name.endsWith('.test.ts'))
  .map(entry => entry.name).sort();
if (!tests.length) throw new Error('No tests/*.test.ts files found');
for (const test of tests) await import(pathToFileURL(resolve(directory, test)).href);

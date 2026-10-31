// Regression pin for the Code component docs previews. ComponentPreview
// deliberately keeps a webp fallback under its live canvas, so a stale
// or incompatible wasm scene can otherwise fail silently and leave the
// page looking correct while it is only showing the screenshot.
//
// Require the checked-in module to instantiate the exact `code` and
// `code-diff` scenes used by /components/code. Runs after `next build`
// as part of `pnpm check`.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const docsDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const wasmPath = join(docsDir, "public", "wasm", "component-preview.wasm");
const vocabPath = join(docsDir, "src", "lib", "component-vocab.json");
const bytes = readFileSync(wasmPath);
const vocab = JSON.parse(readFileSync(vocabPath, "utf8"));
const { instance } = await WebAssembly.instantiate(bytes, {});
const exports = instance.exports;
const sceneNames = ["code", "code-diff"];

if (
  typeof exports.preview_code_diff_metadata_round_trip !== "function" ||
  exports.preview_code_diff_metadata_round_trip() !== 1
) {
  throw new Error(
    "the checked-in component-preview.wasm truncates code-diff metadata above line 96 on wasm32",
  );
}

for (const sceneName of sceneNames) {
  const scene = new TextEncoder().encode(sceneName);
  const scenePtr = exports.preview_alloc(scene.length);

  if (!scenePtr) {
    throw new Error(`${sceneName} WASM preview check could not allocate its scene name`);
  }

  new Uint8Array(exports.memory.buffer).set(scene, scenePtr);
  const handle = exports.preview_create(scenePtr, scene.length, 0);
  exports.preview_free(scenePtr, scene.length);

  if (!handle) {
    throw new Error(
      `the checked-in component-preview.wasm cannot create the \`${sceneName}\` scene; rebuild it with \`zig build docs-wasm-preview\``,
    );
  }

  const width = exports.preview_logical_width(handle);
  const height = exports.preview_logical_height(handle);
  exports.preview_destroy(handle);
  const expectedWidth = vocab.previews[sceneName].width / 2;
  const expectedHeight = vocab.previews[sceneName].height / 2;

  if (width !== expectedWidth || height !== expectedHeight) {
    throw new Error(
      `the ${sceneName} WASM preview is ${width}x${height}; expected the catalog's ${expectedWidth}x${expectedHeight} scene`,
    );
  }

  console.log(`${sceneName} WASM preview check passed: live scene instantiated at ${width}x${height}`);
}

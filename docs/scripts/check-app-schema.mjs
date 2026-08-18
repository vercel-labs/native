import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const docsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = path.resolve(docsRoot, "..");
const publishedPath = path.join(repoRoot, "apps", "schema", "public", "app", "v1.json");
const legacyPath = path.join(docsRoot, "public", "schemas", "app.schema.json");
const packagePath = path.join(repoRoot, "packages", "native-sdk", "schemas", "app.schema.json");
const deploymentPath = path.join(repoRoot, "apps", "schema", "vercel.json");
const publishedBytes = fs.readFileSync(publishedPath);
const schema = JSON.parse(publishedBytes.toString("utf8"));
const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));

assert.equal(schema.$id, "https://schema.native-sdk.dev/app/v1.json");
assert.equal(schema.$defs.persist.properties.debounce_ms.minimum, 0);
assert.equal(schema.$defs.persist.properties.debounce_ms.maximum, 60_000);
assert.equal(schema.$defs.frontend.properties.dev.properties.timeout_ms.minimum, 1);
assert.equal(schema.$defs.frontend.properties.dev.properties.timeout_ms.maximum, 4_294_967_295);
assert.equal(schema.$defs.dmg.properties.window_width.minimum, 320);
assert.equal(schema.$defs.dmg.properties.window_width.maximum, 2_000);
assert.equal(schema.$defs.dmg.properties.window_height.minimum, 240);
assert.equal(schema.$defs.dmg.properties.window_height.maximum, 1_400);
assert.equal(schema.$defs.dmg.properties.icon_size.minimum, 32);
assert.equal(schema.$defs.dmg.properties.icon_size.maximum, 256);
assert.deepEqual(fs.readFileSync(legacyPath), publishedBytes, "legacy docs schema differs from canonical v1");
assert.deepEqual(fs.readFileSync(packagePath), publishedBytes, "published and npm-packaged app schemas differ");
assert.equal(deployment.outputDirectory, "public");
// /app.json aliases the canonical schema; every other path 302-redirects
// away from the single-purpose schema domain (files like /app/v1.json are
// served directly and take precedence over this rewrites list).
assert.deepEqual(deployment.rewrites, [
  { source: "/app.json", destination: "/app/v1.json" },
  { source: "/(.*)", destination: "https://native-sdk.dev" },
]);
assert.ok(deployment.headers.some((entry) => entry.source === "/app/v1.json"));
assert.ok(deployment.headers.some((entry) => entry.source === "/app.json"));

console.log("app schema check passed: canonical deployment, runtime bounds, and npm mirror agree");

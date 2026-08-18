import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const docsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = path.resolve(docsRoot, "..");
const publishedPath = path.join(docsRoot, "public", "schemas", "app.schema.json");
const packagePath = path.join(repoRoot, "packages", "native-sdk", "schemas", "app.schema.json");
const publishedBytes = fs.readFileSync(publishedPath);
const schema = JSON.parse(publishedBytes.toString("utf8"));

assert.equal(schema.$defs.persist.properties.debounce_ms.minimum, 0);
assert.equal(schema.$defs.persist.properties.debounce_ms.maximum, 60_000);
assert.equal(schema.$defs.frontend.properties.dev.properties.timeout_ms.minimum, 1);
assert.equal(schema.$defs.frontend.properties.dev.properties.timeout_ms.maximum, 4_294_967_295);
assert.deepEqual(fs.readFileSync(packagePath), publishedBytes, "published and npm-packaged app schemas differ");

console.log("app schema check passed: runtime timeout bounds and npm mirror agree");

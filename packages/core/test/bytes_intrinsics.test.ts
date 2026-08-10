import test from "node:test";
import assert from "node:assert/strict";
import { asciiBytes, utf8Bytes } from "../sdk/core.ts";

test("asciiBytes returns exact ASCII and rejects Unicode", () => {
  assert.deepEqual([...asciiBytes("app.refresh")], [...new TextEncoder().encode("app.refresh")]);
  assert.throws(() => asciiBytes("Loading…"), {
    name: "RangeError",
    message: /use utf8Bytes/,
  });
});

test("utf8Bytes matches TextEncoder for BMP, astral, and lone-surrogate text", () => {
  for (const value of [
    "ASCII",
    "Today · Loading… — café",
    "agent ✓ ⚠ ○",
    "emoji 😀",
    "lone high \ud800",
    "lone low \udc00",
  ]) {
    assert.deepEqual([...utf8Bytes(value)], [...new TextEncoder().encode(value)], JSON.stringify(value));
  }
});

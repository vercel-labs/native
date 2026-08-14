import test from "node:test";
import assert from "node:assert/strict";
import { asciiBytes, utf8Bytes, windowDescriptor } from "../sdk/core.ts";

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

test("windowDescriptor fills canonical window defaults", () => {
  const descriptor = windowDescriptor({
    label: asciiBytes("settings"),
    canvasLabel: asciiBytes("settings-canvas"),
    titlebar: "chromeless",
    closePolicy: "hide",
  });
  assert.deepEqual([...descriptor.label], [...asciiBytes("settings")]);
  assert.equal(descriptor.width, 480);
  assert.equal(descriptor.height, 360);
  assert.equal(descriptor.resizable, true);
  assert.equal(descriptor.titlebar, "chromeless");
  assert.equal(descriptor.closePolicy, "hide");
  assert.equal(descriptor.onCloseCommand.length, 0);
});

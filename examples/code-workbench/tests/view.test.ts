import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

const backend = process.env.NATIVE_SDK_TEST_VIEW_BACKEND;
const compare = (snapshots: NativeSnapshot[]) => {
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (!reference) return;
  const values = snapshots.map(({ viewBackend, ...s }) => s);
  if (backend === "zig") writeFileSync(`${reference}.code.json`, JSON.stringify(values));
  else assert.deepEqual(values, JSON.parse(readFileSync(`${reference}.code.json`, "utf8")));
};
const bytes = (value: unknown) => Buffer.from(value as number[]).toString("utf8");

test("code drafts preserve file indentation, selection, independent history, source changes and replay", async () => {
  const app = await NativeApp.start({ width: 960, height: 520 });
  try {
    let s = await app.snapshot();
    if (backend) assert.equal(s.viewBackend, backend);
    const snapshots = [s], save = () => snapshots.push(s);
    const field = (name = "TypeScript draft") => findWidget(s, { role: "textbox", name });
    const button = (name: string) => findWidget(s, { role: "button", name });
    const key = async (key: string) => { s = await app.key(field().view, key); save(); };
    const focus = async (name = "TypeScript draft") => { s = await app.action(field(name), "focus"); save(); };
    const set = async (name: string, text: string) => { s = await app.setText(field(name), text); save(); };
    const select = async (name: string, anchor: number, focus: number) => { s = await app.selectText(field(name), anchor, focus); save(); };
    const click = async (name: string) => { s = await app.click(button(name)); save(); };
    const value = (name: string) => s.model[name] as { text: number[]; anchor: number; focus: number; compStart: number };
    const text = (name: string, expected: string) => assert.equal(bytes(value(name).text), expected);
    const firstId = field().id, secondId = field("Python draft").id;
    await focus(); await key("end"); await key("tab");
    text("typescript", "function greet() {\n    return 'café';\n}\n    ");
    assert.equal(field().focused, true);
    await key("cmd+z"); text("typescript", "function greet() {\n    return 'café';\n}\n");
    await key("cmd+shift+z");
    await focus("Python draft"); await key("end"); await key("tab");
    text("python", "def greet():\n\treturn '日本'\n\t");
    await key("enter"); text("python", "def greet():\n\treturn '日本'\n\t\n");
    await click("Refresh"); assert.equal(field().id, firstId); assert.equal(field("Python draft").id, secondId);
    await focus(); await key("cmd+z"); text("typescript", "function greet() {\n    return 'café';\n}\n");
    await key("cmd+shift+z");
    // Tab replaces a backward UTF-8 selection as one edit; Undo restores it.
    await set("TypeScript draft", "    café🙂\r\n");
    await select("TypeScript draft", 13, 4); await focus(); await key("tab");
    text("typescript", "        \r\n");
    await key("cmd+z"); text("typescript", "    café🙂\r\n");
    assert.equal(value("typescript").anchor, 13); assert.equal(value("typescript").focus, 4);
    await key("cmd+shift+z"); text("typescript", "        \r\n");
    // Tied conventions follow the caret's own logical line.
    await set("TypeScript draft", "\tx\n  y"); await select("TypeScript draft", 1, 1); await key("tab");
    text("typescript", "\t\tx\n  y");
    await key("cmd+z"); await select("TypeScript draft", 4, 4); await key("tab");
    text("typescript", "\tx\n    y");
    // New app source starts a fresh history; the other draft stays unchanged.
    const python = value("python");
    await click("Use tabs"); await focus(); await key("end"); await key("tab");
    text("typescript", "function greet() {\n\treturn 'café';\n}\n\t");
    await key("cmd+z"); await key("cmd+z");
    text("typescript", "function greet() {\n\treturn 'café';\n}\n");
    assert.deepEqual(value("python"), python);
    await click("Use spaces"); await focus(); await key("end");
    s = await app.composeText(field(), "日本🙂"); save();
    s = await app.commitComposition(field()); save();
    text("typescript", "function greet() {\n    return 'café';\n}\n日本🙂");
    await key("cmd+z"); text("typescript", "function greet() {\n    return 'café';\n}\n");
    await key("cmd+shift+z");
    await click("Toggle line numbers"); assert.equal(s.model.numbered, false);
    await click("Toggle line numbers"); assert.equal(s.model.numbered, true);
    await click("Hide TypeScript"); assert.ok(!s.widgets.some(w => w.name === "TypeScript draft"));
    await click("Refresh"); await click("Hide TypeScript"); assert.equal(field().id, firstId);
    text("typescript", "function greet() {\n    return 'café';\n}\n日本🙂");
    await focus(); const before = value("typescript"); await key("shift+tab");
    assert.deepEqual(value("typescript"), before); assert.equal(field().focused, false);
    // Horizontal/vertical overflow retains the source and caret through refresh.
    const long = "    const café = '" + "日本".repeat(180) + "';\n" + "    next();\n".repeat(50);
    await set("TypeScript draft", long); await focus(); await key("end"); await key("tab");
    await click("Refresh"); text("typescript", long + "    ");
    await click("New workbench"); assert.notEqual(field().id, firstId); assert.notEqual(field("Python draft").id, secondId);
    text("python", "def greet():\n\treturn '日本'\n");
    const replay = await app.verifyReplay();
    assert.deepEqual(replay.snapshot.model, s.model); assert.deepEqual(replay.snapshot.widgets, s.widgets);
    snapshots.push(replay.snapshot); compare(snapshots);
  } finally { await app.close(); }
});

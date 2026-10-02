import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

const backend = process.env.NATIVE_SDK_TEST_VIEW_BACKEND;
const compare = (snapshots: NativeSnapshot[]) => {
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (!reference) return;
  const values = snapshots.map(({ viewBackend, ...snapshot }) => snapshot);
  if (backend === "zig") writeFileSync(`${reference}.writing.json`, JSON.stringify(values));
  else assert.deepEqual(values, JSON.parse(readFileSync(`${reference}.writing.json`, "utf8")));
};
const bytes = (value: unknown) => Buffer.from(value as number[]).toString("utf8");
const primary = process.platform === "darwin" ? "super" : "ctrl";

test("writing editors preserve UTF-8 editing, multiline Enter policy, IME, identity and replay", async () => {
  const app = await NativeApp.start({ width: 960, height: 720 });
  try {
    let s = await app.snapshot();
    if (backend) assert.equal(s.viewBackend, backend);
    const snapshots = [s], save = () => snapshots.push(s);
    const field = (name: string) => findWidget(s, { role: "textbox", name });
    const button = (name: string) => findWidget(s, { role: "button", name });
    const value = (name: string) => s.model[name] as { text: number[]; anchor: number; focus: number; compStart: number; compEnd: number };
    const expectText = (name: string, text: string) => assert.equal(bytes(value(name).text), text, name);
    const key = async (key: string) => { s = await app.key(field("Subject").view, key); save(); };
    const focus = async (name: string) => { s = await app.action(field(name), "focus"); save(); };
    const set = async (name: string, text: string) => { s = await app.setText(field(name), text); save(); };
    const select = async (name: string, anchor: number, focus: number) => { s = await app.selectText(field(name), anchor, focus); save(); };
    const click = async (name: string) => { s = await app.click(button(name)); save(); };
    const noteId = field("Note").id, messageId = field("Message").id;
    await set("Subject", "A\r\nB café"); expectText("subject", "AB café");
    await focus("Subject"); await key("end"); await key("shift+arrowleft");
    assert.equal(value("subject").focus, Buffer.byteLength("AB caf"));
    await key("backspace"); expectText("subject", "AB caf");
    await key(`${primary}+a`); await key("backspace"); expectText("subject", "");
    await set("Note", "Café\nnotes"); await focus("Note"); await key("end");
    await key("enter"); expectText("draft", "Café\nnotes\n"); assert.equal(s.model.submits, 0);
    await key("shift+enter"); expectText("draft", "Café\nnotes\n\n");
    await key(`${primary}+enter`); assert.equal(s.model.submits, 1); assert.equal(bytes(s.model.submitted), "Café\nnotes\n\n");
    await key("alt+enter"); assert.equal(s.model.submits, 1); expectText("draft", "Café\nnotes\n\n");
    await set("Note", "one café\nthree words"); await focus("Note"); await key("end");
    await key("alt+arrowleft"); assert.equal(value("draft").focus, Buffer.byteLength("one café\nthree "));
    await key("shift+alt+arrowleft"); await key("backspace"); expectText("draft", "one café\nwords");
    await key("home"); await key("delete"); expectText("draft", "ne café\nwords");
    await select("Note", 0, Buffer.byteLength("ne café")); await key("backspace"); expectText("draft", "\nwords");
    await set("Note", "alpha\nbeta"); await focus("Note"); await key("end");
    if (process.platform === "darwin") {
      await key("super+backspace"); expectText("draft", "alpha\n");
    } else {
      await key("ctrl+backspace"); expectText("draft", "alpha\n");
    }
    await set("Note", "Draft"); await select("Note", 5, 5);
    s = await app.composeText(field("Note"), "\n日本"); save(); expectText("draft", "Draft\n日本");
    assert.ok(value("draft").compStart >= 0);
    s = await app.cancelComposition(field("Note")); save(); expectText("draft", "Draft");
    s = await app.composeText(field("Note"), "\n日本"); save();
    s = await app.commitComposition(field("Note")); save(); expectText("draft", "Draft\n日本");
    assert.equal(value("draft").compStart, -1);
    await click("Refresh"); assert.equal(field("Note").id, noteId); expectText("draft", "Draft\n日本");
    await set("Message", "Hello café"); await focus("Message"); await key("end");
    await key("enter"); assert.equal(s.model.submits, 2); expectText("chat", "Hello café");
    await key("shift+enter"); expectText("chat", "Hello café\n");
    await key(`${primary}+enter`); assert.equal(s.model.submits, 3);
    await click("Toggle Enter to send"); assert.equal(s.model.sendOnEnter, false);
    await focus("Message"); await key("enter"); expectText("chat", "Hello café\n\n"); assert.equal(s.model.submits, 3);
    await key(`${primary}+enter`); assert.equal(s.model.submits, 4);
    await click("Lock editors"); const locked = s.model;
    for (const name of ["Subject", "Note", "Message"]) {
      const target = field(name), point = { x: target.bounds.x + 20, y: target.bounds.y + 20 };
      assert.equal(target.enabled, false);
      s = await app.pointer(target, "down", point); save();
      s = await app.pointer(target, "up", point); save();
      await key("backspace"); assert.deepEqual(s.model, locked);
    }
    await click("Lock editors"); await click("Hide note");
    assert.ok(!s.widgets.some(w => w.role === "textbox" && w.name === "Note"));
    await click("Refresh"); await click("Hide note"); assert.equal(field("Note").id, noteId); assert.equal(field("Message").id, messageId);
    expectText("draft", "Draft\n日本");
    await focus("Subject"); await key("tab"); assert.equal(field("Note").focused, true);
    await key("shift+tab"); assert.equal(field("Subject").focused, true);
    await click("New desk"); assert.notEqual(field("Note").id, noteId); expectText("chat", "Hello"); assert.equal(s.model.submits, 0);
    // Real pointer events derive click counts from journaled timestamps.
    // Probe a plain caret to aim inside the word without pinning font widths.
    const pointer = async (name: string, phase: "down" | "drag" | "up", x: number, y: number, shift = false) => {
      s = await app.pointer(field(name), phase, { x, y }, { x: 0, y: 0 }, { shift }); save();
    };
    const pauseClicks = async () => { for (let i = 0; i < 33; i++) s = await app.frame(); };
    const aim = async (name: string, model: string, start: number, end: number, line = 0) => {
      await pauseClicks();
      const bounds = field(name).bounds, y = bounds.y + 16 + line * 20;
      for (let x = bounds.x + 12; x < bounds.x + bounds.width - 8; x += 8) {
        await pointer(name, "down", x, y); await pointer(name, "up", x, y);
        const caret = value(model).focus;
        if (caret >= start && caret < end) return { x, y };
      }
      assert.fail(`No plain caret inside ${name} range ${start}..${end}`);
    };
    const clickPoint = async (name: string, point: { x: number; y: number }, shift = false) => {
      await pointer(name, "down", point.x, point.y, shift); await pointer(name, "up", point.x, point.y, shift);
    };
    const selection = (name: string, anchor: number, focus: number) => {
      assert.equal(value(name).anchor, anchor); assert.equal(value(name).focus, focus);
    };
    await set("Subject", "one café!!!  last");
    const word = await aim("Subject", "subject", 4, 9);
    await clickPoint("Subject", word); selection("subject", 4, 9);
    await clickPoint("Subject", word); selection("subject", 0, 18);
    await set("Note", "one café three\r\nfour last");
    const lastWord = await aim("Note", "draft", 10, 15);
    const middle = await aim("Note", "draft", 4, 9);
    await pointer("Note", "down", middle.x, middle.y); selection("draft", 4, 9);
    await pointer("Note", "drag", lastWord.x, lastWord.y); selection("draft", 4, 15);
    await pointer("Note", "drag", field("Note").bounds.x + 12, middle.y); selection("draft", 9, 0);
    await pointer("Note", "drag", middle.x, middle.y); selection("draft", 4, 9);
    await pointer("Note", "up", middle.x, middle.y);
    await clickPoint("Note", middle); selection("draft", 0, 15);
    await key("backspace"); expectText("draft", "\r\nfour last");
    await set("Note", "one café three\r\nfour last");
    const first = await aim("Note", "draft", 0, 3);
    await select("Note", 5, 5);
    await clickPoint("Note", first, true); selection("draft", 9, 0);
    await click("Refresh"); selection("draft", 9, 0);
    await click("Hide note"); await click("Hide note");
    await click("Lock editors"); const pointerLocked = s.model;
    for (let i = 0; i < 3; i++) await clickPoint("Note", first);
    assert.deepEqual(s.model, pointerLocked);
    await click("Lock editors"); await click("New desk");
    // The retained editor and model use the same portable reducer. Verify
    // exact byte stops, history replay, and composition replacements together.
    // `cmd` is automation's portable primary modifier; `ctrl` is raw Control.
    await set("Note", "é\r\n🙂z"); await focus("Note");
    await select("Note", 1, 3); selection("draft", 0, 2);
    await key("arrowright"); selection("draft", 2, 2);
    await key("arrowright"); selection("draft", 4, 4);
    await key("shift+arrowright"); selection("draft", 4, 8);
    await key("backspace"); expectText("draft", "é\r\nz");
    await key("cmd+z"); expectText("draft", "é\r\n🙂z"); selection("draft", 4, 8);
    await key("cmd+shift+z"); expectText("draft", "é\r\nz");
    await set("Note", "one café  last"); await focus("Note"); await key("end");
    await key("alt+backspace"); expectText("draft", "one café  ");
    await key("alt+backspace"); expectText("draft", "one ");
    await key("cmd+z"); expectText("draft", "one café  ");
    await select("Note", 0, 3);
    s = await app.composeText(field("Note"), "日"); save(); expectText("draft", "日 café  ");
    s = await app.composeText(field("Note"), "日本"); save(); expectText("draft", "日本 café  ");
    s = await app.commitComposition(field("Note")); save(); assert.equal(value("draft").compStart, -1);
    await key("cmd+z"); expectText("draft", "one café  ");
    await key("cmd+shift+z"); expectText("draft", "日本 café  ");
    await set("Message", "other draft"); await select("Message", 0, 5);
    s = await app.composeText(field("Message"), "é🙂"); save(); expectText("chat", "é🙂 draft");
    s = await app.cancelComposition(field("Message")); save(); expectText("chat", " draft");
    expectText("draft", "日本 café  ");
    await set("Subject", "é\r\n🙂"); expectText("subject", "é🙂");
    await click("Refresh"); await click("Hide note"); await click("Hide note");
    expectText("draft", "日本 café  "); expectText("subject", "é🙂"); expectText("chat", " draft");
    await click("New desk");
    const replay = await app.verifyReplay(); assert.deepEqual(replay.snapshot.model, s.model); assert.deepEqual(replay.snapshot.widgets, s.widgets);
    snapshots.push(replay.snapshot); compare(snapshots);
  } finally { await app.close(); }
});

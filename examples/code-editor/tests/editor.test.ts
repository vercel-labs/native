import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

const utf8 = new TextEncoder();
const text = (bytes: unknown) => new TextDecoder().decode(Uint8Array.from(bytes as number[]));
type Request = NativeSnapshot["effects"]["requests"][number];
function word(value: number): number[] { return [value & 255, value >>> 8]; }
function field(value: string): number[] { const bytes = [...utf8.encode(value)]; return [...word(bytes.length), ...bytes]; }
function reply(request: Request, body: readonly number[] = [], failure = ""): Uint8Array {
  assert.equal(request.bytes[0], 2);
  const length = request.bytes[2]! | request.bytes[3]! << 8;
  assert.ok(length > 0 && length <= 32);
  return Uint8Array.from([...request.bytes.slice(0, 4 + length), ...field(failure), ...body]);
}
function request(snapshot: NativeSnapshot, name: string, owner: number): Request {
  const found = snapshot.effects.requests.filter(value => value.name === name && value.bytes[1] === owner);
  assert.equal(found.length, 1);
  return found[0]!;
}
function compare(snapshots: readonly NativeSnapshot[]): void {
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (!reference) return;
  const values = snapshots.map(({ viewBackend, ...snapshot }) => snapshot);
  if (process.env.NATIVE_SDK_TEST_VIEW_BACKEND === "zig") writeFileSync(`${reference}.code-editor.json`, JSON.stringify(values));
  else assert.deepEqual(values, JSON.parse(readFileSync(`${reference}.code-editor.json`, "utf8")));
}
function session(snapshot: NativeSnapshot, owner = 0): { browser: { status: number[]; documents: { editor: { text: number[] } }[] } } {
  return (snapshot.model.sessions as unknown as ReturnType<typeof session>[])[owner]!;
}
async function openFolder(app: NativeApp, owner: number, window: number): Promise<NativeSnapshot> {
  let snapshot = await app.menu("open-folder", window);
  const picker = request(snapshot, "native-sdk.dialog.openDirectory", owner);
  snapshot = await app.respond(picker.key, reply(picker, field("/editor-fixture")));
  const directory = request(snapshot, "native-sdk.fs.listDirectory", owner);
  return app.respond(directory.key, reply(directory, [0, ...word(2), 1, ...field("src"), 0, ...field("file.ts")]));
}

test("compiled Code Editor retains directory, editing, rename, file terminals and complete replay", async () => {
  await using app = await NativeApp.start({ width: 1120, height: 720 });
  const snapshots: NativeSnapshot[] = [];
  let snapshot = await openFolder(app, 0, 1); snapshots.push(snapshot);
  snapshot = await app.action(findWidget(snapshot, { role: "treeitem", name: "src" }), "focus");
  snapshot = await app.key("code-editor-canvas", "arrowright");
  const scan = request(snapshot, "native-sdk.fs.listDirectory", 0);
  snapshot = await app.respond(scan.key, reply(scan, [0, ...word(1), 0, ...field("nested.ts")])); snapshots.push(snapshot);
  snapshot = await app.click(findWidget(snapshot, { role: "treeitem", name: "file.ts" }));
  const read = snapshot.effects.files[0]!;
  assert.equal(read.op, "read"); assert.equal(read.path, "/editor-fixture/file.ts");
  snapshot = await app.fileResult(read.key, "read", utf8.encode("const café = 1;\n")); snapshots.push(snapshot);
  const editor = () => findWidget(snapshot, { role: "textbox", name: "file.ts" });
  snapshot = await app.setText(editor(), "const 日本 = 2;\n"); snapshots.push(snapshot);
  assert.equal(text(session(snapshot).browser.documents[0]!.editor.text), "const 日本 = 2;\n");
  snapshot = await app.menu("save-file");
  const write = snapshot.effects.files[0]!;
  assert.equal(write.op, "write"); assert.equal(text(write.bytes), "const 日本 = 2;\n");
  snapshot = await app.setText(editor(), "const 日本 = 3;\n");
  snapshot = await app.menu("save-file");
  snapshot = await app.fileResult(write.key, "write", new Uint8Array());
  const queued = snapshot.effects.files[0]!;
  assert.equal(queued.op, "write"); assert.equal(text(queued.bytes), "const 日本 = 3;\n");
  snapshot = await app.fileResult(queued.key, "write", new Uint8Array()); snapshots.push(snapshot);
  snapshot = await app.action(findWidget(snapshot, { role: "treeitem", name: "file.ts" }), "focus");
  snapshot = await app.key("code-editor-canvas", "enter");
  snapshot = await app.setText(findWidget(snapshot, { role: "textbox", name: "Rename item" }), "renamed.ts");
  snapshot = await app.key("code-editor-canvas", "enter");
  const rename = request(snapshot, "native-sdk.fs.renameExclusive", 0);
  snapshot = await app.respond(rename.key, reply(rename)); snapshots.push(snapshot);
  assert.ok(snapshot.widgets.some(value => value.name === "renamed.ts" && value.role === "treeitem"));
  assert.equal(text(session(snapshot).browser.documents[0]!.editor.text), "const 日本 = 3;\n");
  const replay = await app.verifyReplay();
  assert.ok(replay.events > 0 && replay.effects > 0 && replay.checkpoints > 0);
  assert.deepEqual(replay.snapshot, snapshot); snapshots.push(replay.snapshot);
  compare(snapshots);
});

test("five Code Editor windows own independent requests and reject retired session results", async () => {
  await using app = await NativeApp.start({ width: 1120, height: 720 });
  let snapshot = await app.snapshot();
  for (let owner = 1; owner < 5; owner++) {
    snapshot = await app.menu("new-window");
    const focus = request(snapshot, "native-sdk.window.focusResult", owner);
    snapshot = await app.respond(focus.key, reply(focus));
  }
  assert.equal(snapshot.windows.length, 5);
  snapshot = await app.menu("new-window", snapshot.windows.find(value => value.label === "code-editor-5")!.id);
  assert.equal(text(session(snapshot, 4).browser.status), "Window limit reached (5).");
  const secondary = snapshot.windows.find(value => value.label === "code-editor-2")!;
  snapshot = await app.menu("open-folder", secondary.id);
  const retired = request(snapshot, "native-sdk.dialog.openDirectory", 1);
  snapshot = await app.closeWindow(secondary);
  assert.ok(!snapshot.effects.requests.some(value => value.key === retired.key));
  snapshot = await app.menu("new-window");
  const focus = request(snapshot, "native-sdk.window.focusResult", 1);
  snapshot = await app.respond(focus.key, reply(focus));
  const reopened = snapshot.windows.find(value => value.label === "code-editor-2")!;
  snapshot = await app.menu("open-folder", reopened.id);
  const picker = request(snapshot, "native-sdk.dialog.openDirectory", 1);
  assert.notDeepEqual(reply(picker), reply(retired));
  snapshot = await app.menu("open-folder", 1);
  const main = request(snapshot, "native-sdk.dialog.openDirectory", 0);
  snapshot = await app.respond(picker.key, utf8.encode("PermissionDenied"), false);
  assert.equal(text(session(snapshot, 1).browser.status), "The folder dialog could not be opened.");
  assert.equal(text(session(snapshot, 0).browser.status), "");
  snapshot = await app.respond(main.key, reply(main, word(0)));
  assert.equal(text(session(snapshot, 0).browser.status), "Folder selection cancelled.");
  const replay = await app.verifyReplay();
  assert.deepEqual(replay.snapshot, snapshot);
});

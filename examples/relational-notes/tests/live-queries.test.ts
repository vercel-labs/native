import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget } from "@native-sdk/core/testing";

const text = (value: unknown) => new TextDecoder().decode(new Uint8Array(value as number[]));
function page(rows: readonly (readonly [number, string, number])[]): Uint8Array {
  const parts: Buffer[] = [];
  const u32 = (n: number) => { const b = Buffer.alloc(4); b.writeUInt32LE(n); parts.push(b); };
  const bytes = (s: string) => { const b = Buffer.from(s); u32(b.length); parts.push(b); };
  const integer = (n: number) => { const b = Buffer.alloc(9); b[0] = 1; b.writeBigInt64LE(BigInt(n), 1); parts.push(b); };
  u32(3); u32(rows.length); for (const name of ["id", "title", "updated_at"]) bytes(name);
  for (const [id, title, updated] of rows) { integer(id); parts.push(Buffer.from([3])); bytes(title); integer(updated); }
  return new Uint8Array(Buffer.concat(parts));
}

test("live queries retain slots, restart on parameters, pause, replace keys and replay complete database effects", async () => {
  const app = await NativeApp.start({ width: 860, height: 620 });
  try {
    let s = await app.snapshot(); const snapshots = [s];
    const save = () => snapshots.push(s);
    const press = async (name: string, role = "button") => { s = await app.click(findWidget(s, { role, name })); save(); };
    const live = () => s.effects.databases.filter(db => db.kind === "live");
    const folder = () => live().find(db => db.tables.includes("note") && !db.tables.includes("search_index"))!;
    const search = () => live().find(db => db.tables.includes("search_index"))!;
    assert.equal(live().length, 2);
    assert.equal(findWidget(s, { role: "switch", name: "Live updates" }).value, 1);
    const initialFolder = folder(), initialSearch = search();
    await press("Inbox"); assert.deepEqual(live(), [initialFolder, initialSearch]);
    await press("Seed relational demo");
    const transaction = s.effects.databases.find(db => db.kind === "exec")!; assert.ok(transaction);
    s = await app.databaseResult(transaction.key, "exec"); save();
    assert.equal(text(s.model.status), "Transaction committed; live queries refresh automatically");
    s = await app.databaseResult(folder().key, "page", page([[2, "Ship checked SQLite", 200], [1, "Build native views", 100]])); save();
    s = await app.databaseResult(folder().key, "done"); save(); assert.equal((s.model.notes as unknown[]).length, 2);
    s = await app.databaseResult(search().key, "page", page([[1, "Build native views", 100]])); save();
    s = await app.databaseResult(search().key, "done"); save(); assert.equal((s.model.matches as unknown[]).length, 1);
    await press("Archive"); assert.equal(folder().key, initialFolder.key); assert.notEqual(folder().generation, initialFolder.generation);
    assert.deepEqual(search(), initialSearch); assert.deepEqual(folder().params, [{ integer: 2 }]);
    s = await app.databaseResult(folder().key, "page", page([[3, "Archive old draft", 50]])); save();
    s = await app.databaseResult(folder().key, "done"); save(); assert.equal((s.model.notes as unknown[]).length, 1);
    const beforeSearch = search(); await press("SQLite"); assert.equal(search().key, beforeSearch.key); assert.notEqual(search().generation, beforeSearch.generation);
    s = await app.databaseResult(search().key, "page", page([[2, "Ship checked SQLite", 200]])); save();
    s = await app.databaseResult(search().key, "done"); save();
    await press("Live updates", "switch"); assert.equal(s.effects.databases.length, 0);
    assert.equal(findWidget(s, { role: "switch", name: "Live updates" }).value, 0);
    assert.equal(findWidget(s, { role: "button", name: "Restart live queries" }).enabled, false);
    await press("Add note transaction"); const write = s.effects.databases.find(db => db.kind === "exec")!;
    s = await app.databaseResult(write.key, "exec"); save(); assert.equal(s.effects.databases.length, 0);
    await press("Live updates", "switch"); assert.equal(live().length, 2);
    assert.equal(findWidget(s, { role: "switch", name: "Live updates" }).value, 1);
    assert.equal(findWidget(s, { role: "button", name: "Restart live queries" }).enabled, true);
    const resumed = live(); await press("Restart live queries"); assert.equal(live().length, 2);
    assert.deepEqual(live().map(db => db.key), resumed.map(db => db.key));
    assert.ok(live().every((db, i) => db.generation !== resumed[i]!.generation));
    const restarted = live();
    s = await app.databaseResult(folder().key, "done", undefined, "busy"); save(); assert.equal(text(s.model.status), "busy");
    assert.deepEqual(live(), restarted);
    s = await app.databaseResult(folder().key, "page", page([[4, "A live-query note", 4]])); save();
    s = await app.databaseResult(folder().key, "done"); save();
    const replay = await app.verifyReplay(); assert.ok(replay.events > 0 && replay.effects > 0 && replay.checkpoints > 0);
    assert.deepEqual(replay.snapshot.model, s.model); assert.deepEqual(replay.snapshot.effects.databases, s.effects.databases);
    s = replay.snapshot; save();
    const backend = process.env.NATIVE_SDK_TEST_VIEW_BACKEND, reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
    if (backend) assert.equal(s.viewBackend, backend);
    if (reference) {
      const values = snapshots.map(({ viewBackend, ...snapshot }) => snapshot);
      if (backend === "zig") writeFileSync(`${reference}.live-queries.json`, JSON.stringify(values));
      else assert.deepEqual(values, JSON.parse(readFileSync(`${reference}.live-queries.json`, "utf8")));
    }
  } finally { await app.close(); }
});

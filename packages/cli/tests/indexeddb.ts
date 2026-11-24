// IndexedDB over SQLite: version changes, object stores with inline and out-of-line keys and key
// generators, put/get/getAll/getAllKeys/count/delete/clear, IDBKeyRange, a duplicate key, a
// version error, values surviving a close and reopen, deleteDatabase and databases().
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><style>body { margin: 0; }</style></head><body>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
function done(request: any): Promise<any> {
  return new Promise((resolve, reject) => {
    request.onsuccess = (): void => resolve(request.result);
    request.onerror = (): void => reject(request.error);
  });
}
function completed(tx: any): Promise<void> {
  return new Promise((resolve, reject) => { tx.oncomplete = (): void => resolve(); tx.onabort = (): void => reject(tx.error); });
}
function walk(request: any): Promise<string[]> {
  return new Promise((resolve, reject) => {
    const out: string[] = [];
    request.onerror = (): void => reject(request.error);
    request.onsuccess = (): void => {
      const cursor = request.result;
      if (cursor === null || out.length > 50) { resolve(out); return; }
      out.push(String(cursor.key) + ":" + String(cursor.primaryKey));
      cursor.continue();
    };
  });
}

async function main(): Promise<void> {
  const first = indexedDB.open("first", 1);
  first.onupgradeneeded = (): void => {
    const db = first.result;
    try {
      db.createObjectStore("items", { keyPath: "id" });
      db.createObjectStore("logs", { autoIncrement: true });
      db.createObjectStore("out");
      db.createObjectStore("gen", { keyPath: "id", autoIncrement: true });
      const people = db.createObjectStore("people", { keyPath: "id" });
      people.createIndex("byName", "name", { unique: true });
      people.createIndex("byTag", "tag", { multiEntry: true });
      log("upgraded " + db.objectStoreNames.join(","));
    } catch (e: any) {
      log("upgrade failed " + e.name + " " + e.message);
    }
  };
  const db = await done(first);
  log("open " + db.name + " " + db.version + " " + db.objectStoreNames.join(","));
  let guard = "";
  try { db.createObjectStore("nope"); } catch (e: any) { guard = e.name; }
  log("create outside " + guard);

  const tx = db.transaction("items", "readwrite");
  const store = tx.objectStore("items");
  log("keypath " + store.keyPath + " " + store.autoIncrement);
  const p1 = store.put({ id: 1, name: "one" });
  const p2 = store.put({ id: 2, name: "two" });
  const k1 = done(p1);
  const k2 = done(p2);
  await completed(tx);
  log("keys " + (await k1) + "," + (await k2) + " " + tx.mode);

  const read = db.transaction("items");
  const items = read.objectStore("items");
  // Every request a transaction makes goes out before the first await: a transaction is only
  // active while the turn that made its requests lasts.
  const rGet = items.get(1);
  const rMissing = items.get(99);
  const rAll = items.getAll();
  const rAllKeys = items.getAllKeys();
  const rGetKey = items.getKey(2);
  const rRange = items.getAll(IDBKeyRange.lowerBound(2));
  const rCount = items.count();
  const rCountRange = items.count(IDBKeyRange.upperBound(1));
  // Every request's handlers go on before the transaction runs them, as a browser requires.
  const wGet = done(rGet);
  const wMissing = done(rMissing);
  const wAll = done(rAll);
  const wAllKeys = done(rAllKeys);
  const wGetKey = done(rGetKey);
  const wRange = done(rRange);
  const wCount = done(rCount);
  const wCountRange = done(rCountRange);
  const one = await wGet;
  log("get " + one.name);
  log("missing " + (await wMissing === undefined));
  const all = await wAll;
  log("all " + all.map((v: any): number => v.id).join(","));
  log("allkeys " + (await wAllKeys).join(","));
  log("getkey " + (await wGetKey));
  const range = await wRange;
  log("range " + range.map((v: any): number => v.id).join(","));
  log("count " + (await wCount) + " " + (await wCountRange));

  const dup = db.transaction("items", "readwrite");
  await done(dup.objectStore("items").add({ id: 1, name: "dup" })).catch((e: any) => log("duplicate " + e.name));

  const gen = db.transaction("logs", "readwrite");
  const logs = gen.objectStore("logs");
  const g1 = logs.add({ line: "a" });
  const g2 = logs.add({ line: "b" });
  const kg1 = done(g1);
  const kg2 = done(g2);
  log("generated " + (await kg1) + "," + (await kg2));

  // A generated inline key goes into the stored clone, not the caller's object.
  const genInline = db.transaction("gen", "readwrite");
  const plain: any = { name: "first" };
  const gi = genInline.objectStore("gen").put(plain);
  const giDone = done(gi);
  log("generated inline " + (await giDone) + " " + ("id" in plain));

  const out = db.transaction("out", "readwrite");
  await done(out.objectStore("out").put({ when: new Date(1234), bytes: new Uint8Array([1, 2, 3]) }, "k"));
  const cloned = await done(db.transaction("out").objectStore("out").get("k"));
  log("clone " + (cloned.when instanceof Date) + " " + cloned.when.getTime() + " " + new Uint8Array(cloned.bytes).join(","));
  const arrKey = ["a,b", 2];
  const arrTx = db.transaction("out", "readwrite");
  const arrPut = done(arrTx.objectStore("out").put({ kind: "array" }, arrKey));
  await arrPut;
  const arrGet = done(db.transaction("out").objectStore("out").get(arrKey));
  log("array key " + ((await arrGet).kind === "array"));

  const blobPut = done(db.transaction("out", "readwrite").objectStore("out").put(
    { blob: new Blob(["hi"], { type: "text/plain" }) }, "blob"));
  await blobPut;
  const blobGet = await done(db.transaction("out").objectStore("out").get("blob"));
  log("blob " + (blobGet.blob instanceof Blob) + " " + blobGet.blob.size + " " + blobGet.blob.type);
  log("blob text " + (await blobGet.blob.text()));

  const cNext = db.transaction("items");
  log("cursor next " + (await walk(cNext.objectStore("items").openCursor())).join(","));
  const cPrev = db.transaction("items");
  log("cursor prev " + (await walk(cPrev.objectStore("items").openCursor(undefined, "prev"))).join(","));
  const cRange = db.transaction("items");
  log("cursor range " + (await walk(cRange.objectStore("items").openCursor(IDBKeyRange.lowerBound(2)))).join(","));
  const cKeys = db.transaction("items");
  log("cursor keys " + (await walk(cKeys.objectStore("items").openKeyCursor())).join(","));

  // The calls a browser refuses: a key behind the cursor, a count below one, a step past the end
  // and an update through a key cursor.
  const cursorGuardTx = db.transaction("items");
  await new Promise<void>((resolve, reject) => {
    const req = cursorGuardTx.objectStore("items").openCursor();
    req.onerror = (): void => reject(req.error);
    req.onsuccess = (): void => {
      const cursor = req.result;
      if (cursor === null) { resolve(); return; }
      if (cursor.key === 1) {
        try { cursor.continue(0); } catch (e) { log("cursor behind " + (e as any).name); }
        try { cursor.advance(0); } catch (e) { log("cursor advance " + (e as any).name); }
      }
      cursor.continue();
    };
  });

  const cursorEndedTx = db.transaction("items");
  await new Promise<void>((resolve, reject) => {
    const req = cursorEndedTx.objectStore("items").openCursor(IDBKeyRange.only(1));
    let last: any = null;
    req.onerror = (): void => reject(req.error);
    req.onsuccess = (): void => {
      if (req.result !== null) { last = req.result; req.result.continue(); return; }
      try { last.continue(); } catch (e) { log("cursor ended " + (e as any).name); }
      resolve();
    };
  });

  try { db.transaction("items").objectStore("items").openCursor({} as any); } catch (e) { log("cursor bad query " + (e as any).name); }
  const nullQueryTx = db.transaction("items");
  log("cursor null " + (await walk(nullQueryTx.objectStore("items").openCursor(null))).length);

  const keyOnlyTx = db.transaction("items");
  await new Promise<void>((resolve, reject) => {
    const req = keyOnlyTx.objectStore("items").openKeyCursor();
    req.onerror = (): void => reject(req.error);
    req.onsuccess = (): void => {
      const cursor = req.result;
      if (cursor === null) { resolve(); return; }
      try { cursor.update({ name: "nope" }); } catch (e) { log("key cursor update " + (e as any).name); }
      resolve();
    };
  });

  const people = db.transaction("people", "readwrite");
  const ps = people.objectStore("people");
  const pa = ps.add({ id: 1, name: "ann", tag: ["a", "b"] });
  const pb = ps.add({ id: 2, name: "bob", tag: ["b"] });
  const pc = ps.add({ id: 3, name: "cat" });
  const ka = done(pa);
  const kb = done(pb);
  const kc = done(pc);
  await completed(people);
  await ka;
  await kb;
  await kc;
  const pr = db.transaction("people");
  const pstore = pr.objectStore("people");
  log("indexes " + pstore.indexNames.join(","));
  const byName = pstore.index("byName");
  const byTag = pstore.index("byTag");
  const q1 = done(byName.get("bob"));
  const q2 = done(byName.getKey("cat"));
  const q3 = done(byName.getAll());
  const q4 = done(byTag.getAll("b"));
  const q5 = done(byTag.getAllKeys());
  const q6 = done(byTag.count("b"));
  log("byName get " + (await q1).id);
  log("byName key " + (await q2));
  log("byName all " + (await q3).map((v: any): string => v.name).join(","));
  log("byTag b " + (await q4).map((v: any): number => v.id).join(","));
  log("byTag keys " + (await q5).join(","));
  log("byTag count " + (await q6));
  const tagCursor = db.transaction("people");
  log("index cursor " + (await walk(tagCursor.objectStore("people").index("byTag").openCursor())).join(","));
  const tagUnique = db.transaction("people");
  log("index unique " + (await walk(tagUnique.objectStore("people").index("byTag").openCursor(undefined, "nextunique"))).join(","));
  const unique = db.transaction("people", "readwrite");
  await done(unique.objectStore("people").add({ id: 4, name: "ann" })).catch((e: any) => log("unique " + e.name));

  // A cursor rewrites the record it is on, then deletes another one.
  const rewrite = db.transaction("items", "readwrite");
  const upReq = rewrite.objectStore("items").openCursor(IDBKeyRange.only(1));
  await new Promise<void>((resolve, reject) => {
    upReq.onsuccess = (): void => {
      const cursor = upReq.result;
      if (cursor === null) { resolve(); return; }
      const up = cursor.update({ id: 1, name: "uno" });
      up.onsuccess = (): void => { cursor.continue(); };
      up.onerror = (): void => reject(up.error);
    };
    upReq.onerror = (): void => reject(upReq.error);
  });
  const uname = await done(db.transaction("items").objectStore("items").get(1));
  log("cursor update " + uname.name);

  const removal = db.transaction("items", "readwrite");
  const delReq = removal.objectStore("items").openCursor(IDBKeyRange.only(2));
  await new Promise<void>((resolve, reject) => {
    delReq.onsuccess = (): void => {
      const cursor = delReq.result;
      if (cursor === null) { resolve(); return; }
      const del = cursor.delete();
      del.onsuccess = (): void => resolve();
      del.onerror = (): void => reject(del.error);
    };
    delReq.onerror = (): void => reject(delReq.error);
  });
  const left = await done(db.transaction("items").objectStore("items").count());
  log("after delete " + left);
  db.close();

  const second = indexedDB.open("first", 2);
  second.onupgradeneeded = (e: any): void => {
    log("upgrade " + e.oldVersion + "->" + e.newVersion);
    second.result.createObjectStore("more");
    const people = second.transaction.objectStore("people");
    people.createIndex("byName2", "name");
    people.deleteIndex("byName2");
    people.deleteIndex("byTag");
  };
  const db2 = await done(second);
  log("v2 " + db2.version + " " + db2.objectStoreNames.join(","));
  log("v2 indexes " + db2.transaction("people").objectStore("people").indexNames.join(","));
  const saved = await done(db2.transaction("items").objectStore("items").get(1));
  log("saved " + saved.name);

  const lower = indexedDB.open("first", 1);
  await done(lower).catch((e: any) => log("lower " + e.name));
  db2.close();

  await done(indexedDB.deleteDatabase("first"));
  const fresh = indexedDB.open("first");
  fresh.onupgradeneeded = (e: any): void => { log("fresh upgrade " + e.oldVersion + "->" + e.newVersion); };
  const db3 = await done(fresh);
  log("fresh " + db3.version);
  db3.close();

  const listed = await indexedDB.databases();
  log("dbs " + listed.map((d: any): string => d.name + ":" + d.version).join(","));
  log("done");
}
main().catch((e: any) => { log("fail " + e.name + " " + e.message); });
`;

const EXPECTED = [
  "upgraded items,logs,out,gen,people",
  "open first 1 items,logs,out,gen,people",
  "create outside InvalidStateError",
  "keypath id false",
  "keys 1,2 readwrite",
  "get one",
  "missing true",
  "all 1,2",
  "allkeys 1,2",
  "getkey 2",
  "range 2",
  "count 2 1",
  "duplicate ConstraintError",
  "generated 1,2",
  "generated inline 1 false",
  "clone true 1234 1,2,3",
  "array key true",
  "blob true 2 text/plain",
  "blob text hi",
  "cursor next 1:1,2:2",
  "cursor prev 2:2,1:1",
  "cursor range 2:2",
  "cursor keys 1:1,2:2",
  "cursor behind DataError",
  "cursor advance TypeError",
  "cursor ended InvalidStateError",
  "cursor bad query DataError",
  "cursor null 2",
  "key cursor update InvalidStateError",
  "indexes byName,byTag",
  "byName get 2",
  "byName key 3",
  "byName all ann,bob,cat",
  "byTag b 1,2",
  "byTag keys 1,1,2",
  "byTag count 2",
  "index cursor a:1,b:1,b:2",
  "index unique a:1,b:1",
  "unique ConstraintError",
  "cursor update uno",
  "after delete 1",
  "upgrade 1->2",
  "v2 2 items,logs,out,gen,people,more",
  "v2 indexes byName",
  "saved uno",
  "lower VersionError",
  "fresh upgrade 0->1",
  "fresh 1",
  "dbs first:1",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "htmlc-indexeddb-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "wait 1000", NATIVE_STORAGE: join(dir, "data", "localStorage.json") };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.stderr !== "") console.log("     stderr " + JSON.stringify(r.stderr));
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}: ${JSON.stringify(got.slice(EXPECTED.length))}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

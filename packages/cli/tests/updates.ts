// The update check: the version comparison, the update document, the config a build writes, and
// an app that checks a local server and exposes the newer version through navigator.serviceWorker.
//   npm test

import { spawn, spawnSync } from "node:child_process";
import { copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { compareVersions, parseUpdateDocument } from "../shared/updates.ts";
import { updateConfigOf, writeUpdateConfig, UPDATE_CONFIG_FILE } from "../compiler/updates.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

// --- versions and the update document -----------------------------------------
check("a newer version is newer", compareVersions("2.1.0", "2.0.9") === 1);
check("an older version is older", compareVersions("1.9.9", "2.0.0") === -1);
check("the same version is equal", compareVersions("1.2.3", "1.2.3") === 0);
check("missing numbers are zero", compareVersions("2", "2.0.0") === 0, String(compareVersions("2", "2.0.0")));
check("a prerelease is older than its release", compareVersions("2.0.0-beta", "2.0.0") === -1);
check("a release is newer than its prerelease", compareVersions("2.0.0", "2.0.0-rc.1") === 1);
check("a leading v is accepted", compareVersions("v2.0.1", "2.0.0") === 1);

const doc = parseUpdateDocument({ version: "2.0.0", url: "https://example.com/app.dmg", notes: "Faster." });
check("an update document is read", doc !== null && doc.version === "2.0.0" && doc.url === "https://example.com/app.dmg" && doc.notes === "Faster.",
  JSON.stringify(doc));
check("a document without a version is rejected", parseUpdateDocument({ url: "https://example.com/app.dmg" }) === null);
check("a document with a non-http URL keeps no URL",
  parseUpdateDocument({ version: "2.0.0", url: "file:///tmp/app.dmg" })?.url === "", JSON.stringify(parseUpdateDocument({ version: "2.0.0", url: "file:///tmp/app.dmg" })));
check("a document that isn't an object is rejected", parseUpdateDocument([]) === null && parseUpdateDocument("2.0.0") === null);

// --- what a build writes ------------------------------------------------------
const dir = mkdtempSync(join(tmpdir(), "native-updates-"));
const app = join(dir, "app");
mkdirSync(app, { recursive: true });
writeFileSync(join(app, "app.webmanifest"), JSON.stringify({
  name: "Notes Native",
  version: "2.1.0",
  update_url: "https://updates.example.com/notes.json",
}));
writeFileSync(join(app, "index.html"), `<!doctype html><html><head>
<title>Notes</title><link rel="manifest" href="app.webmanifest"></head>
<body><h1 id="h">notes</h1></body></html>`);
const resources = join(dir, "out", "notes.resources");
mkdirSync(resources, { recursive: true });
const config = writeUpdateConfig(resources, join(app, "index.html"));
const configFile = join(resources, ".native", UPDATE_CONFIG_FILE);
check("the build writes the update config", existsSync(configFile));
check("the config names the app's URL", config !== null && config.url === "https://updates.example.com/notes.json", JSON.stringify(config));
check("the config names the app's version", config !== null && config.version === "2.1.0", JSON.stringify(config));
check("the config names the app", config !== null && config.name === "Notes Native", JSON.stringify(config));
check("the config reads back", JSON.parse(readFileSync(configFile, "utf8")).url === "https://updates.example.com/notes.json");

// A page that drops update_url stops checking, and a stale file goes.
writeFileSync(join(app, "app.webmanifest"), JSON.stringify({ name: "Notes Native", version: "2.1.0" }));
check("no update_url means no check", updateConfigOf(resources, join(app, "index.html")) === null);
writeUpdateConfig(resources, join(app, "index.html"));
check("a build without update_url removes the old config", !existsSync(configFile));

// A relative update_url can't be fetched from anywhere, so it is a warning, not a config.
writeFileSync(join(app, "app.webmanifest"), JSON.stringify({ name: "Notes", update_url: "updates.json" }));
check("a relative update_url turns the check off", updateConfigOf(resources, join(app, "index.html")) === null);

// A release build's app.json is the app's own statement, and wins over the page.
writeFileSync(join(resources, ".native", "app.json"), JSON.stringify({
  name: "Release Notes", version: "3.0.0", updateUrl: "https://updates.example.com/release.json",
}));
const fromBundle = updateConfigOf(resources, join(app, "index.html"));
check("app.json supplies the update config", fromBundle !== null && fromBundle.url === "https://updates.example.com/release.json" &&
  fromBundle.version === "3.0.0", JSON.stringify(fromBundle));

// --- an app that checks a server ---------------------------------------------
const UPDATE = { version: "9.9.9", url: "https://example.com/Notes-9.9.9.dmg", notes: "A newer Notes." };
let served = 0;
const server = http.createServer((req, res) => {
  if ((req.url ?? "").split("?")[0] === "/update.json") {
    served++;
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(UPDATE));
  } else {
    res.writeHead(404);
    res.end("no");
  }
});
await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
const address = server.address();
const port = address !== null && typeof address === "object" ? address.port : 0;
const BASE = `http://127.0.0.1:${port}`;

const live = join(dir, "live");
mkdirSync(live, { recursive: true });
writeFileSync(join(live, "app.webmanifest"), JSON.stringify({
  name: "Live Notes", version: "1.0.0", update_url: `${BASE}/update.json`,
}));
writeFileSync(join(live, "index.html"), `<!doctype html><html><head><title>Live Notes</title>
<link rel="manifest" href="app.webmanifest"></head>
<body><h1 id="h">updates</h1><script type="module" src="app.ts"></script></body></html>`);
writeFileSync(join(live, "app.ts"), `
async function main(): Promise<void> {
  const registration = await navigator.serviceWorker.getRegistration();
  console.log("registration " + (registration ? "yes" : "no"));
  if (!registration) return;
  let found = "none";
  registration.addEventListener("updatefound", () => { found = registration.installing ? registration.installing.state : "none"; });
  await registration.update();
  console.log("found " + found);
  console.log("waiting " + (registration.waiting ? registration.waiting.state + " " + registration.waiting.scriptURL : "none"));
}
main().catch((e) => console.log("error " + e));
`);
const exe = join(dir, "out", "live");
const build = spawnSync("node", ["compiler/cli.ts", "build", live, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
check("the build wrote the runtime's update config", existsSync(join(dir, "out", "live.resources", ".native", UPDATE_CONFIG_FILE)));

/** Runs the app while this process keeps the server answering: spawnSync would block its event
 *  loop and every request would time out. */
function runApp(file: string, env: Record<string, string> = {}): Promise<{ stdout: string; stderr: string; status: number | null }> {
  return new Promise((resolve) => {
    const child = spawn(file, [], { env: { ...process.env, NATIVE_STEPS: "wait 3000 | print #h", ...env } });
    let stdout = "", stderr = "";
    child.stdout.on("data", (d: Buffer) => { stdout += d.toString(); });
    child.stderr.on("data", (d: Buffer) => { stderr += d.toString(); });
    child.on("close", (status) => resolve({ stdout, stderr, status }));
  });
}

const run = await runApp(exe);
const lines = run.stdout.split("\n").filter((l) => l !== "");
check("the app finds its registration", lines.includes("registration yes"), run.stdout + run.stderr);
check("updatefound names the installing worker", lines.includes("found installing"), run.stdout + run.stderr);
check("the newer version is waiting with its artifact URL", lines.includes("waiting installed https://example.com/Notes-9.9.9.dmg"), run.stdout + run.stderr);
check("the app checked the server", served > 0, String(served));

// An app that didn't opt in has no registration and fetches nothing.
const copy = join(dir, "optout");
mkdirSync(copy, { recursive: true });
copyFileSync(exe, join(copy, "live"));
cpSync(join(dir, "out", "live.resources"), join(copy, "live.resources"), { recursive: true });
rmSync(join(copy, "live.resources", ".native", UPDATE_CONFIG_FILE), { force: true });
const before = served;
const optout = await runApp(join(copy, "live"));
const optLines = optout.stdout.split("\n").filter((l) => l !== "");
check("an app without update_url has no registration", optLines.includes("registration no"), optout.stdout + optout.stderr);
check("an app without update_url fetches nothing", served === before, `${before} -> ${served}`);

server.close();
process.exit(failed === 0 ? 0 : 1);

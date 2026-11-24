// @font-face with a data: URL: the build decodes the font into the app's bundle and the text
// measures exactly as the installed face it came from does. A data: URL that isn't a font is
// reported and the family falls back, as a face that can't load does.
//   npm test

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const CANDIDATES = [
  { file: "/System/Library/Fonts/Supplemental/Times New Roman.ttf", family: "Times New Roman" },
  { file: "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf", family: "DejaVu Serif" },
  { file: "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", family: "DejaVu Sans" },
];
const found = CANDIDATES.find((c) => existsSync(c.file));
if (found === undefined) {
  console.log("ok   @font-face data: URLs need a font file to embed (skipped)");
  console.log("\nall passed");
  process.exit(0);
}

const fontUrl = "data:font/ttf;base64," + readFileSync(found.file).toString("base64");
const fontName = createHash("sha1").update(fontUrl).digest("hex").slice(0, 20) + ".ttf";

const PAGE = `<!doctype html>
<html><head><meta name="htmlc-window" content="width=500, height=300"><style>
body { margin: 0; font-size: 20px; }
span { white-space: pre; }
@font-face { font-family: DataFace; src: url("${fontUrl}") format("truetype"); }
@font-face { font-family: BogusFace; src: url("data:text/plain;base64,aGk="); }
</style></head><body>
<span id="data" style="font-family: DataFace">Hamburgefonstiv</span>
<span id="named" style="font-family: '${found.family}'">Hamburgefonstiv</span>
<span id="missing" style="font-family: NoSuchFace123">Hamburgefonstiv</span>
<span id="bogus" style="font-family: BogusFace">Hamburgefonstiv</span>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const width = (id: string): number => Math.round(document.getElementById(id)!.getBoundingClientRect().width * 100) / 100;
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    console.log("data=" + width("data"));
    console.log("named=" + width("named"));
    console.log("missing=" + width("missing"));
    console.log("bogus=" + width("bogus"));
  });
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

/** Every file under `dir`, by path. */
function walk(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) walk(path, out);
    else out.push(path);
  }
  return out;
}

const dir = mkdtempSync(join(tmpdir(), "htmlc-font-data-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

check("only the data: URL that isn't a font is reported", (build.stderr.match(/isn't a font this build can decode/g) ?? []).length === 1, build.stderr);
check("the face is copied into the bundle", walk(dir).some((p) => p.endsWith("/_data/" + fontName) || p.endsWith("\\_data\\" + fontName)),
  walk(dir).filter((p) => p.endsWith(fontName)).join(", "));

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 0 | frame 0" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const lines = r.stdout.split("\n").filter((l) => l !== "");
for (const line of lines) console.log(`     got ${JSON.stringify(line)}`);
const values: Record<string, number> = {};
for (const line of lines) {
  const eq = line.indexOf("=");
  if (eq > 0) values[line.slice(0, eq)] = Number(line.slice(eq + 1));
}
check("the data face measures as the installed face does", values.data === values.named,
  `${values.data} vs ${values.named}`);
check("the installed face measures unlike the fallback", values.named !== values.missing,
  `${values.named} vs ${values.missing}`);
check("a face that can't load falls back", values.bogus === values.missing, `${values.bogus} vs ${values.missing}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

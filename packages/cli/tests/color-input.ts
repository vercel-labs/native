// A colour field holds a simple colour: any CSS colour the value text names, kept as lowercase
// `#rrggbb`, or black when it names none. Its box is the UA's 50 by 27 swatch, sized along the
// box's own axes, so a vertical writing mode turns it upright.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=100"><style>
#v { writing-mode: vertical-rl; }
</style></head><body>
<input id="plain" type="color">
<input id="v" type="color">
<input id="attr" type="color" value="red">
<input id="bad" type="color" value="12px">
<input id="hex" type="color" value="#00FF00">
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const out = [];
const put = (k: string, v: string) => out.push(k + "=" + v);
// Every value a colour field takes, and what its value reads back as.
const values: string[] = [
  "", "#ffffff", "#FFFFFF", "#0F0F0F", "#fff", "fffffff", "#gggggg", "foobar",
  " #ffffff ", "crimson", "transparent", "inherit", "currentColor", "rgb(1,1,1)",
  "rgb(1, 1, 1, 1)", "hsl(150deg 100 53.5)", "color(display-p3 1 0 0)", "ActiveBorder",
];
for (let i = 0; i < values.length; i++) {
  const el = document.createElement("input");
  el.type = "color";
  el.value = values[i];
  put("t" + i, el.value);
}
// A field with no value is black, and one whose markup names a colour it can't hold is too.
const plain = document.getElementById("plain") as HTMLInputElement;
put("plain", plain.value);
const attr = document.getElementById("attr") as HTMLInputElement;
put("attr", attr.getAttribute("value") ?? "");
put("attrValue", attr.value);
put("badValue", (document.getElementById("bad") as HTMLInputElement).value);
put("hex", (document.getElementById("hex") as HTMLInputElement).value);
// A field whose type changes takes the new type's value: the old text is kept when it is a
// colour, and black takes its place when it isn't.
const changed = document.createElement("input");
changed.value = "hello";
changed.type = "color";
put("changedFromText", changed.value);
const kept = document.createElement("input");
kept.value = "#00ff00";
kept.type = "color";
put("changedFromColour", kept.value);
// The UA's box, and the same box turned upright by the writing mode.
const style = getComputedStyle(plain);
put("width", style.width);
put("height", style.height);
put("inline", style.inlineSize);
put("block", style.blockSize);
put("verticalWidth", getComputedStyle(document.getElementById("v") as HTMLInputElement).width);
put("verticalHeight", getComputedStyle(document.getElementById("v") as HTMLInputElement).height);
console.log("OUT " + out.join("|"));
`;

const dir = mkdtempSync(join(tmpdir(), "native-color-input-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 1" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const line = (r.stdout + r.stderr).split("\n").find((l) => l.startsWith("OUT ")) ?? "";
const got = line.replace(/^OUT /, "");
const field = (name: string): string => {
  const at = got.indexOf("|" + name + "=");
  if (at < 0) return "";
  const start = at + name.length + 2;
  const end = got.indexOf("|", start);
  return got.slice(start, end < 0 ? got.length : end);
};
const values = ["", "#ffffff", "#FFFFFF", "#0F0F0F", "#fff", "fffffff", "#gggggg", "foobar",
  " #ffffff ", "crimson", "transparent", "inherit", "currentColor", "rgb(1,1,1)",
  "rgb(1, 1, 1, 1)", "hsl(150deg 100 53.5)", "color(display-p3 1 0 0)", "ActiveBorder"];
const expected = ["#000000", "#ffffff", "#ffffff", "#0f0f0f", "#ffffff", "#000000", "#000000",
  "#000000", "#ffffff", "#dc143c", "#000000", "#000000", "#000000", "#010101", "#010101",
  "#12ff88", "#ff0000", "#767676"];
for (let i = 0; i < values.length; i++) {
  const want = expected[i];
  check(`${JSON.stringify(values[i])} reads back as ${want}`, field("t" + i) === want, got);
}
check("a field with no value is black", field("plain") === "#000000", got);
check("markup that names a colour keeps it", field("attrValue") === "#ff0000", got);
check("markup that names no colour reads black", field("badValue") === "#000000", got);
// The attribute keeps the text it was given; the field's value is the colour.
check("the value attribute is kept as written", field("attr") === "red", got);
check("a markup colour is lowercased", field("hex") === "#00ff00", got);
check("text that isn't a colour becomes black when the type changes", field("changedFromText") === "#000000", got);
check("a colour survives the type change", field("changedFromColour") === "#00ff00", got);
check("the field is 50 by 27", field("width") === "50px" && field("height") === "27px", got);
check("its inline size is its width and its block size its height",
  field("inline") === "50px" && field("block") === "27px", got);
check("a vertical writing mode turns the box upright",
  field("verticalWidth") === "27px" && field("verticalHeight") === "50px", got);
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

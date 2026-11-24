// What `native check` prints when a stylesheet has the vendor-prefixed selectors and properties a
// framework ships: one line for them all, the repeated hint once, and a duplicate warning once.
// The collapsing is what keeps a real problem from being lost in a framework's preflight, so the
// rules are checked here rather than in a build.
//   npm test

import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { compileFrontEnd } from "../compiler/build.ts";
import { Diagnostics } from "../compiler/diagnostics.ts";

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` — ${detail}`}`);
}

const HINT = "supported pseudo-classes are :hover";

// A unit: two vendor selectors, one ordinary one twice, and a vendor property.
const diags = new Diagnostics();
diags.warn("app.css", 1, 1, "selector '::-webkit-datetime-edit' is not supported yet; skipped", HINT);
diags.warn("app.css", 2, 1, "selector '::-moz-focus-inner' is not supported yet; skipped", HINT);
diags.warn("app.css", 3, 1, "selector ':has(> img)' is not supported yet; skipped", HINT);
diags.warn("app.css", 3, 1, "selector ':has(> img)' is not supported yet; skipped", HINT);
diags.warn("app.css", 4, 1, "'-webkit-font-smoothing' is not supported yet; ignored");
diags.warn("app.css", 5, 1, "selector ':has(> a)' is not supported yet; skipped", HINT);

const shown = diags.collapsed();
ok("a duplicate warning is shown once", shown.length === 4, JSON.stringify(shown.map((d) => d.message)));
const vendor = shown.find((d) => d.message.startsWith("2 vendor-prefixed selectors"));
ok("vendor-prefixed selectors are one line",
  vendor !== undefined && vendor.message.includes("::-webkit-datetime-edit") && vendor.message.includes("::-moz-focus-inner"),
  JSON.stringify(vendor));
ok("the vendor line carries no hint", vendor !== undefined && vendor.hint === undefined);
const property = shown.find((d) => d.message.includes("-webkit-font-smoothing"));
ok("a vendor property is named as one",
  property !== undefined && property.message.startsWith("1 vendor-prefixed property is not supported yet; ignored"), JSON.stringify(property));
const has = shown.filter((d) => d.message.includes(":has("));
ok("two ordinary selectors stay two warnings", has.length === 2, JSON.stringify(has.map((d) => d.message)));
ok("the hint is printed with the first only", has[0].hint === HINT && has[1].hint === undefined);

const text = diags.format(false);
ok("the formatted text prints the hint once", text.split(HINT).length === 2, text);
ok("the formatted text lists each vendor selector once",
  text.split("::-webkit-datetime-edit").length === 2 && text.split("::-moz-focus-inner").length === 2, text);

// The real front end: a stylesheet like Tailwind's preflight, whose unsupported selectors are
// reported through the same path `native check` prints.
const dir = mkdtempSync(join(tmpdir(), "native-diagnostics-"));
const app = join(dir, "app");
mkdirSync(app);
writeFileSync(join(app, "index.html"),
  `<!doctype html><html><head><title>Tailwind</title><link rel="stylesheet" href="style.css"></head><body><p>hi</p></body></html>`);
writeFileSync(join(app, "style.css"), [
  ".a { color: red }",
  "::-webkit-datetime-edit { padding: 0 }",
  "::-webkit-datetime-edit-fields-wrapper { padding: 0 }",
  "::-moz-focus-inner { border: 0 }",
  "::details-content { margin: 0 }",
  "p { -webkit-font-smoothing: antialiased }",
  "",
].join("\n"));
const { diags: appDiags } = compileFrontEnd(join(app, "index.html"));
const lines = appDiags.format(false).split("\n").filter((l) => l.includes("vendor-prefixed selector"));
ok("one line gathers the stylesheet's vendor selectors", lines.length === 1, JSON.stringify(lines));
ok("the stylesheet's ordinary warnings are not swallowed", appDiags.format(false).includes("::details-content"),
  appDiags.format(false));
ok("the vendor selectors are named in the group", lines[0]?.includes("::-webkit-datetime-edit") === true, lines[0]);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

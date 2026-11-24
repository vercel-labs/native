// A CommonJS dependency that opens with `"use strict"` and requires a sibling file and a package.
// The build copies the whole require graph — every file the package's own requires reach — and
// points each specifier at the copies, so nothing it loads is left behind. The DOM globals it
// uses are required there, after the directive, so the file stays strict.
//   npm test

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { vendorSources } from "../compiler/build.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

function install(dir: string, files: Record<string, string>): void {
  for (const [path, text] of Object.entries(files)) {
    const p = join(dir, path);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, text);
  }
}

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=100"></head>
<body><div id="root"></div><script src="app.ts"></script></body></html>
`;

const LABEL = `"use strict";

module.exports = { label: "cjs" };
`;

const SIZE = `"use strict";

module.exports = { size: 20 };
`;

// A CommonJS package: its entry names a sibling file, another package, and a DOM global.
const ENTRY = `"use strict";

const { label } = require("./label");
const { makeBox } = require("dep-two");

module.exports = {
  make() {
    const el = makeBox();
    el.textContent = label;
    document.title = label;
    return el;
  },
};
`;

const dir = mkdtempSync(join(tmpdir(), "native-cjs-"));
const app = join(dir, "app");
install(app, {
  "index.html": PAGE,
  "app.ts": `import { make } from "fake-cjs";\n\ndocument.getElementById("root")!.appendChild(make());\n`,
  "node_modules/fake-cjs/package.json": JSON.stringify({ name: "fake-cjs", main: "index.js" }),
  "node_modules/fake-cjs/index.js": ENTRY,
  "node_modules/fake-cjs/label.js": LABEL,
  // A package whose entry its package.json names, and which requires a file of its own.
  "node_modules/dep-two/package.json": JSON.stringify({ name: "dep-two", main: "lib/main.js" }),
  "node_modules/dep-two/lib/main.js": `"use strict";

const { size } = require("./size");

exports.makeBox = function makeBox() {
  const el = document.createElement("div");
  el.id = "box-" + size;
  return el;
};
`,
  "node_modules/dep-two/lib/size.js": SIZE,
});

const copies = vendorSources(app, join(dir, "src"));
const copyOf = (source: string): string => {
  const out = copies.get(join(app, "node_modules", source));
  if (out === undefined) throw new Error(`${source} was not copied`);
  return out;
};
const read = (source: string): string => readFileSync(copyOf(source), "utf8");

check("the sibling file is copied", copies.has(join(app, "node_modules/fake-cjs/label.js")));
check("the package's entry is copied", copies.has(join(app, "node_modules/dep-two/lib/main.js")));
check("the file the package requires is copied", copies.has(join(app, "node_modules/dep-two/lib/size.js")));
check("a CommonJS file keeps its kind", copyOf("fake-cjs/index.js").endsWith(".cjs"), copyOf("fake-cjs/index.js"));

const entry = read("fake-cjs/index.js");
check('the entry keeps "use strict" first', entry.startsWith('"use strict";'), entry.split("\n")[0]);
check(
  "the DOM globals are required after the directive",
  /^"use strict";\s*const \{ [^}]*\bdocument\b[^}]*\} = require\("[^"]*runtime\/dom\.ts"\);/.test(entry),
  entry.split("\n")[0],
);
check("no import line is added to a CommonJS copy", !/^\s*import\s/m.test(entry));
check("the entry requires the copied sibling", entry.includes(`require("./${basename(copyOf("fake-cjs/label.js"))}")`), entry);
check("the entry requires the copied package", entry.includes(`require("./${basename(copyOf("dep-two/lib/main.js"))}")`), entry);

const main = read("dep-two/lib/main.js");
check('the package keeps "use strict" first', main.startsWith('"use strict";'), main.split("\n")[0]);
check("the package requires the copied file it names", main.includes(`require("./${basename(copyOf("dep-two/lib/size.js"))}")`), main);

check("a file no require reaches is copied as it stands", read("fake-cjs/label.js") === LABEL);
check("a required file keeps its own text", read("dep-two/lib/size.js") === SIZE);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

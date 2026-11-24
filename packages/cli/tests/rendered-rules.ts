// A page whose document a script renders: the HTML holds only a mount point, and the elements and
// classes come from JSX, as they do in a React app. The build's static tree is then just the mount
// point, so dead-rule elimination must keep the element and type rules the rendered nodes can
// match. A page with no script still eliminates rules nothing can match.
//   npm test

import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { compileFrontEnd } from "../compiler/build.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

// Tailwind-shaped CSS: preflight's element rules, a nested space-y utility and a class rule.
const CSS = `h1 { font-size: 2em; }
button, input, select, textarea { font: inherit; }
input::placeholder { opacity: 1; }
.space-y-4 { :where(& > :not(:last-child)) { margin-block-end: calc(0.25rem * 4); } }
.bg-indigo-600 { background-color: #4f46e5; }
.rounded-lg { border-radius: 0.5rem; }
blockquote { color: #000000; }
`;

function app(files: { [path: string]: string }): string {
  const dir = mkdtempSync(join(tmpdir(), "native-rendered-rules-"));
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(dirname(join(dir, path)), { recursive: true });
    writeFileSync(join(dir, path), text);
  }
  return dir;
}

// React's package shape: an entry point that requires the runtime, whose element creation the
// build's import walk doesn't read. The JSX is the app's own, which is what tells the build that
// elements are rendered after it runs.
const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><title>Settings</title><link rel="stylesheet" href="dist.css"></head>
<body><div id="root"></div><script type="module" src="src/app.tsx"></script></body></html>`;

const rendered = app({
  "index.html": PAGE,
  "dist.css": CSS,
  "tsconfig.json": `{"compilerOptions":{"jsx":"react-jsx","strict":true}}`,
  "src/app.tsx": `
import { createRoot } from "react-dom/client";
function App() {
  return (
    <main className="space-y-4 p-4">
      <h1 className="text-2xl font-bold">Settings</h1>
      <button className="rounded-lg bg-indigo-600 px-4 py-1.5">Save</button>
      <input className="border border-slate-300 px-3 py-2" placeholder="Name" />
    </main>
  );
}
createRoot(document.getElementById("root")!).render(<App />);
`,
  "node_modules/react-dom/package.json": `{"name":"react-dom","version":"19.0.0","main":"client.js"}`,
  "node_modules/react-dom/client.js": `module.exports = require("./cjs/client.js");`,
  "node_modules/react-dom/cjs/client.js":
    `function createRoot(el) { return { render: function (vnode) { document.createElement(vnode.type); } }; }\n` +
    `module.exports = { createRoot: createRoot };`,
});

const fe = compileFrontEnd(rendered);
const diags = fe.diags.format(false);
check("a JSX-rendered page keeps the rules its elements need", fe.app.stats.rulesDropped === 0, diags);
check("no rule is reported as matching no element", !/matches no element/.test(diags), diags);
const tags = fe.app.tables.dynTags;
check("the element rules reach the runtime selector table",
  ["h1", "button", "input"].every((t) => tags.includes(t)), JSON.stringify(tags));
const classes = fe.app.tables.ruleClasses.flat();
check("a utility's class rule is kept", classes.includes("bg-indigo-600") && classes.includes("rounded-lg"),
  JSON.stringify(classes));

// The same sheet on a page with no script: nothing can render an h1, so its rule still goes.
const staticPage = app({
  "index.html": `<!doctype html>
<html><head><meta charset="utf-8"><title>Settings</title><link rel="stylesheet" href="dist.css"></head>
<body><div id="root"></div></body></html>`,
  "dist.css": CSS,
});
const plain = compileFrontEnd(staticPage);
const plainDiags = plain.diags.format(false);
check("a static page still removes a rule nothing can match", plain.app.stats.rulesDropped > 0, plainDiags);
check("and reports the rule it removed", /rule 'h1' matches no element and was removed/.test(plainDiags), plainDiags);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

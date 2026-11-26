// An app whose tsconfig names the browser's DOM library can still name HTMLInputElement and
// HTMLDialogElement in casts and in React ref props: those names and the runtime's element
// classes type-check together.   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=320, height=160"></head><body>
<div id="root"></div>
<script type="module" src="app.tsx"></script>
</body></html>`;

const TSCONFIG = JSON.stringify({
  compilerOptions: { target: "ES2022", lib: ["ES2022", "DOM"], strict: true, jsx: "react-jsx" },
});

const APP = `
import { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";

function App() {
  const inputRef = useRef<HTMLInputElement | null>(null);
  const dialogRef = useRef<HTMLDialogElement | null>(null);
  const [log, setLog] = useState("none");
  useEffect(() => {
    const event = new Event("input");
    const target = event.target as HTMLInputElement | null;
    const input = inputRef.current;
    const dialog = dialogRef.current;
    setLog((target === null ? "no-target" : target.value) + "|" +
      (input === null ? "no-input" : input.tagName) + "|" + (dialog === null ? "no-dialog" : dialog.tagName));
  }, []);
  return (
    <div>
      <input ref={inputRef} value="typed" readOnly />
      <dialog ref={dialogRef}>Hi</dialog>
      <p id="log">{log}</p>
    </div>
  );
}
createRoot(document.getElementById("root")!).render(<App />);
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-dom-lib-types-"));
const deps = join(process.cwd(), "..", "..", "examples", "ui-dashboard", "node_modules");
symlinkSync(deps, join(dir, "node_modules"), "dir");
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "tsconfig.json"), TSCONFIG);
writeFileSync(join(dir, "app.tsx"), APP);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
check("an app with the DOM lib compiles its casts and React refs", true);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

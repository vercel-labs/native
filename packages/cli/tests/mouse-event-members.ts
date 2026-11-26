// A MouseEvent (and so a DragEvent or PointerEvent) carries the members a browser's does —
// pageX/pageY, the screen and movement positions, offsetX/offsetY, view, the modifier keys and
// getModifierState — and React's synthetic event copies every one of them. A React drag handler
// typed with the aliased DragEvent import throws while React builds its synthetic event unless
// pageX/pageY exist, so the handlers never run.   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=420, height=320"><style>
body { margin: 0; }
</style></head><body>
<div id="root"></div>
<script type="module" src="app.tsx"></script>
</body></html>`;

const APP = `
import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import type { DragEvent as ReactDragEvent } from "react";

function App() {
  const [log, setLog] = useState("none");
  const [members, setMembers] = useState("members:none");
  useEffect(() => {
    const probe = document.getElementById("probe");
    if (probe === null) return;
    probe.addEventListener("click", (event: MouseEvent) => {
      const scrollX = window.scrollX;
      const scrollY = window.scrollY;
      const pageFits = event.pageX === event.clientX + scrollX && event.pageY === event.clientY + scrollY;
      const viewIsNull = event.view === null;
      const mods = event.getModifierState("Shift");
      const movement = event.movementX === 0 && event.movementY === 0;
      const offset = event.offsetX >= 0 && event.offsetY >= 0;
      setMembers("members:" + (pageFits ? "page" : "bad-page") + " " + (viewIsNull ? "view" : "bad-view") +
        " " + (mods ? "bad-mods" : "mods") + " " + (movement ? "movement" : "bad-movement") +
        " " + (offset ? "offset" : "bad-offset"));
    });
  }, []);
  return (
    <div>
      <div id="probe" style={{ position: "fixed", left: "10px", top: "10px", width: "60px", height: "30px", background: "#cccccc" }}>probe</div>
      <div id="src" draggable="true" onDragStart={(event: ReactDragEvent) => { event.dataTransfer.setData("text/plain", "x"); setLog("start"); }} style={{ position: "fixed", left: "10px", top: "60px", width: "80px", height: "40px", background: "#dddddd" }}>src</div>
      <div id="dst" onDragOver={(event: ReactDragEvent) => { event.preventDefault(); setLog("over"); }} onDrop={(event: ReactDragEvent) => { event.preventDefault(); setLog("drop:" + event.dataTransfer.getData("text/plain")); }} style={{ position: "fixed", left: "10px", top: "130px", width: "80px", height: "60px", background: "#eeeeee" }}>dst</div>
      <div style={{ height: "2000px" }}></div>
      <p id="members">{members}</p>
      <p id="out">{log}</p>
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

const dir = mkdtempSync(join(tmpdir(), "native-mouse-members-"));
const deps = join(process.cwd(), "..", "..", "examples", "notes", "node_modules");
symlinkSync(deps, join(dir, "node_modules"), "dir");
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.tsx"), APP);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
check("builds", true);

const run = spawnSync(exe, [], {
  encoding: "utf8",
  env: {
    ...process.env,
    NATIVE_STEPS: "frame 0 | frame 16 | wheel #probe 200 | frame 16 | click #probe | frame 16 | print #members | drag #src 0 90 | frame 50 | print #out",
  },
});
if (run.status !== 0) throw new Error(`run failed\n${run.stderr}`);
const lines = run.stdout.trim().split("\n");
check("pageX/pageY, view, movement, offset and modifiers match a browser", lines[0] === "members:page view mods movement offset", `got ${JSON.stringify(lines[0])}`);
check("a React drag handler typed with ReactDragEvent runs", lines[1] === "drop:x", `got ${JSON.stringify(lines[1])}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

// Declarative shadow DOM: a <template shadowrootmode> in page markup makes its host's shadow
// root, setHTMLUnsafe does the same for parsed markup, innerHTML leaves the template alone, and
// getHTML writes a serializable root back out in the same form.
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
<html><head><meta name="native-window" content="width=200, height=100"></head><body>
<div id="host"><template shadowrootmode="open" shadowrootserializable><slot name="s1"></slot></template><div id="c1" slot="s1"></div></div>
<div id="multi"><template shadowrootmode="open">Open</template><template shadowrootmode="closed">Closed</template></div>
<div id="modes"><template shadowrootmode="open">x</template></div>
<div id="dyn"></div>
<div id="plain"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function probe(): void {
  const host = document.getElementById("host") as HTMLElement;
  const c1 = document.getElementById("c1")!;
  const root = host.shadowRoot;
  const s1 = root === null ? null : root.querySelector("slot[name=s1]");
  const templateLeft = host.querySelector("template") === null ? "none" : "left";
  const assigned = s1 !== null && c1.assignedSlot === s1 ? "yes" : "no";
  const serializable = root === null ? "no" : root.serializable ? "yes" : "no";
  const dyn = document.getElementById("dyn") as HTMLElement;
  dyn.setHTMLUnsafe('<template shadowrootmode="open"><b id="inside">x</b></template><i id="light">y</i>');
  const dynRoot = dyn.shadowRoot;
  const inside = dynRoot === null ? "none" : dynRoot.querySelector("#inside") === null ? "missing" : "found";
  const plain = document.getElementById("plain")!;
  plain.innerHTML = '<template shadowrootmode="open">x</template>';
  const plainRoot = (plain as HTMLElement).shadowRoot === null ? "none" : "root";
  const plainTemplate = plain.querySelector("template") === null ? "none" : "left";
  // getHTML() serializes an element's children, so the host is serialized through its parent.
  const html = document.body!.getHTML({ serializableShadowRoots: true });
  // An element's own getHTML() writes its own serializable root first.
  const ownHtml = host.getHTML({ serializableShadowRoots: true });
  const back = document.createElement("div");
  back.setHTMLUnsafe(html);
  // The serialized markup is the host element itself, so it is back's child that hosts the root.
  // The body's markup holds several divs; the one whose child is a slot-bearing tree hosts the root.
  let backHost: HTMLElement | null = null;
  for (const kid of back.kids) {
    if (!(kid instanceof HTMLElement)) continue;
    if ((kid as HTMLElement).shadowRoot !== null) backHost = kid as HTMLElement;
  }
  const backRoot = backHost === null || backHost.shadowRoot === null ? "none" : "root";
  // Only the first declarative template makes the root; the next stays a template.
  const multi = document.getElementById("multi") as HTMLElement;
  const multiRoot = multi.shadowRoot;
  const multiText = multiRoot === null ? "" : multiRoot.textContent;
  const multiKids = multi.childElementCount;
  const leftover = multi.firstElementChild as HTMLTemplateElement;
  const leftoverMode = leftover === null ? "none" : leftover.shadowRootMode;
  // attachShadow() with the declarative root's mode returns that root; another mode is refused.
  const modes = document.getElementById("modes") as HTMLElement;
  let modeThrow = false;
  try { modes.attachShadow({ mode: "closed" }); } catch (e) { modeThrow = true; }
  const sameRoot = modes.attachShadow({ mode: "open" });
  const same = sameRoot === modes.shadowRoot ? "same" : "other";
  console.log("OUT "
    + "|root=" + (root === null ? "none" : "yes")
    + "|multi=" + multiText + "/" + multiKids + "/" + leftoverMode
    + "|modeThrow=" + modeThrow + "|same=" + same
    + "|template=" + templateLeft
    + "|assigned=" + assigned
    + "|serializable=" + serializable
    + "|dynInside=" + inside
    + "|plainRoot=" + plainRoot
    + "|plainTemplate=" + plainTemplate
    + "|serialized=" + (html.indexOf('shadowrootmode="open"') >= 0 ? "yes" : "no")
    + "|backRoot=" + backRoot
    + "|ownHtml=" + (ownHtml.indexOf('<template shadowrootmode="open" shadowrootserializable="">') === 0
      && ownHtml.indexOf('<slot name="s1"></slot></template>') > 0 ? "yes" : ownHtml));
}
probe();
`;

const dir = mkdtempSync(join(tmpdir(), "native-declarative-"));
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
check("page markup makes the host's shadow root", field("root") === "yes" && field("template") === "none", got);
check("the light child is assigned to the declarative slot", field("assigned") === "yes", got);
check("the shadowrootserializable attribute reaches the root", field("serializable") === "yes", got);
check("setHTMLUnsafe creates a declarative root", field("dynInside") === "found", got);
check("innerHTML leaves a declarative template alone", field("plainRoot") === "none" && field("plainTemplate") === "left", got);
check("getHTML writes a serializable root", field("serialized") === "yes", got);
check("the serialized markup parses back to a shadow root", field("backRoot") === "root", got);
check("only the first declarative template makes the root", field("multi") === "Open/1/closed", got);
check("an element's own getHTML writes its own root", field("ownHtml") === "yes", got);
check("attachShadow returns the declarative root for its mode and refuses another",
  field("modeThrow") === "true" && field("same") === "same", got);
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

// Regression tests for the DOM node model: real text, comment and fragment nodes, tree
// mutation, attributes, events and the microtask timing a framework's batched render needs.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { inflateSync } from "node:zlib";

interface Image {
  w: number;
  h: number;
  rgba: Uint8Array;
}

function decodePng(path: string): Image {
  const b = readFileSync(path);
  let i = 8;
  let w = 0;
  let h = 0;
  const idat: Buffer[] = [];
  while (i < b.length) {
    const len = b.readUInt32BE(i);
    const type = b.toString("ascii", i + 4, i + 8);
    const data = b.subarray(i + 8, i + 8 + len);
    if (type === "IHDR") {
      w = data.readUInt32BE(0);
      h = data.readUInt32BE(4);
    }
    if (type === "IDAT") idat.push(data);
    i += 12 + len;
  }
  const raw = inflateSync(Buffer.concat(idat));
  const bpp = 4;
  const stride = w * bpp + 1;
  const out = new Uint8Array(w * h * bpp);
  let prev = new Uint8Array(w * bpp);
  for (let y = 0; y < h; y++) {
    const filter = raw[y * stride];
    const line = raw.subarray(y * stride + 1, y * stride + 1 + w * bpp);
    const cur = new Uint8Array(w * bpp);
    for (let x = 0; x < w * bpp; x++) {
      const a = x >= bpp ? cur[x - bpp] : 0;
      const up = prev[x];
      const c = x >= bpp ? prev[x - bpp] : 0;
      let v = line[x];
      if (filter === 1) v += a;
      else if (filter === 2) v += up;
      else if (filter === 3) v += (a + up) >> 1;
      else if (filter === 4) {
        const p = a + up - c;
        const pa = Math.abs(p - a);
        const pb = Math.abs(p - up);
        const pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? up : c;
      }
      cur[x] = v & 255;
    }
    out.set(cur, y * w * bpp);
    prev = cur;
  }
  return { w, h, rgba: out };
}

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=200"><style>
body { margin: 0; font-family: monospace; font-size: 16px; }
#tree { width: 200px; height: 20px; }
#box { width: 200px; height: 20px; }
#box::before { content: "B"; }
#paint { width: 200px; height: 60px; font-size: 40px; line-height: 60px; color: rgb(255, 255, 255); background: rgb(0, 0, 0); }
section.box { width: 120px; height: 30px; }
</style></head><body>
<div id="tree"></div>
<div id="box">AB</div>
<div id="paint"></div>
<div id="host"></div>
<script src="app.ts"></script>
</body></html>`;

// The script logs one line per assertion. The steps click #inner twice (so the once listener
// runs once) and click #paint, whose listener writes text from a promise: the next print and
// the snapshot show it only if the headless runner flushes microtasks between steps.
const SCRIPT = `
const log = (s: string): void => { console.log(s); };

const tree = document.getElementById("tree") as HTMLElement;
const box = document.getElementById("box") as HTMLElement;
const paint = document.getElementById("paint") as HTMLElement;

// --- Node kinds, and a compiled text run is a real text node
const text = box.firstChild as Text;
log("box first=" + text.nodeName + " text=" + text.data + " n=" + box.childNodes.length + " elems=" + box.children.length);
log("box textContent=[" + box.textContent + "]");
log("text nodeType=" + text.nodeType + " data=" + text.data + " nodeValue=" + text.nodeValue + " length=" + text.length);
log("element nodeType=" + box.nodeType + " nodeName=" + box.nodeName + " localName=" + box.localName + " nodeValue=" + String(box.nodeValue));
log("document nodeType=" + document.nodeType + " nodeName=" + document.nodeName);
log("instanceof " + String(box instanceof HTMLElement) + " " + String(box instanceof Element) + " " +
  String(box instanceof Node) + " " + String(text instanceof Text) + " " + String(text instanceof Element) + " " +
  String(text instanceof Node));
// Every interface answers Object.prototype.toString with its own name, as a browser's does.
log("tags " + Object.prototype.toString.call(box) + " " + Object.prototype.toString.call(document) + " " +
  Object.prototype.toString.call(new Event("x")) + " " + Object.prototype.toString.call(document.createTreeWalker(box)));

// --- createTextNode / createComment / createDocumentFragment
const made = document.createTextNode("hi");
log("made text=" + made.nodeType + " " + made.nodeName + " [" + made.data + "]");
const note = document.createComment("note");
log("made comment=" + note.nodeType + " " + note.nodeName + " [" + note.data + "] " + String(note instanceof Comment));
const frag = document.createDocumentFragment();
log("made fragment=" + frag.nodeType + " " + frag.nodeName + " " + String(frag instanceof DocumentFragment));
const one = document.createElement("span");
one.id = "one";
one.textContent = "1";
frag.appendChild(one);
frag.appendChild(made);
frag.appendChild(note);
log("fragment holds " + frag.childNodes.length + " children");

// --- A fragment inserts its children, leaving itself empty
tree.appendChild(frag);
log("inserted " + tree.childNodes.length + " nodes, " + tree.children.length + " elements, fragment " + frag.childNodes.length);
log("tree textContent=[" + tree.textContent + "]");

// --- Sibling links skip neither text nor comments, and element siblings skip both
const head = tree.firstChild as Node;
const tail = tree.lastChild as Node;
const afterOne = one.nextSibling as Node;
const beforeNote = note.previousSibling as Node;
log("first=" + head.nodeName + " last=" + tail.nodeName +
  " next=" + afterOne.nodeName + " prev=" + beforeNote.nodeName);
log("elem siblings " + String(one.nextElementSibling === null) + " " + String((note.previousElementSibling as Element).id === "one"));

// --- insertBefore, replaceChild, removeChild
const two = document.createElement("b");
two.id = "two";
two.textContent = "2";
tree.insertBefore(two, made);
const beforeTwo = two.previousSibling as Element;
const afterTwo = two.nextSibling as Node;
log("insertBefore " + beforeTwo.id + " " + afterTwo.nodeName);
const three = document.createElement("i");
three.textContent = "3";
tree.replaceChild(three, two);
log("replaceChild " + String(tree.querySelector("#two") === null) + " " + three.textContent + " " + (three.parentNode as Node).nodeName);
const removed = tree.removeChild(three);
log("removeChild " + removed.parentNode + " " + tree.childNodes.length + " " + String(three.parentNode === null));

// --- A text node's data updates textContent, and a later style read keeps the new text
text.data = "CD";
log("data update textContent=[" + box.textContent + "]");
log("data update text=[" + text.data + "]");

// --- textContent replaces children with one text node; append turns own text into a node
const fresh = document.createElement("div");
fresh.textContent = "own";
const freshFirst = fresh.firstChild as Node;
log("fresh " + fresh.childNodes.length + " " + freshFirst.nodeName + " [" + freshFirst.nodeValue + "]");
const more = document.createTextNode(" more");
fresh.appendChild(more);
const freshHead = fresh.firstChild as Node;
const freshTail = fresh.lastChild as Text;
log("materialized " + fresh.childNodes.length + " " + freshHead.nodeName + " last=" + freshTail.nodeValue +
  " [" + fresh.textContent + "]");

// --- Attributes, namespaces, ownerDocument
tree.setAttribute("data-x", "1");
log("attr " + tree.getAttribute("data-x") + " " + tree.hasAttribute("data-x"));
tree.removeAttribute("data-x");
log("removed attr " + String(tree.getAttribute("data-x") === null) + " " + tree.hasAttribute("data-x"));
// A renderer passes the property straight through, so booleans arrive as booleans.
tree.setAttribute("disabled", true);
log("boolean attr " + tree.getAttribute("disabled"));
const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
log("namespace " + svg.namespaceURI + " " + svg.localName + " " + box.namespaceURI);
log("owner " + String(text.ownerDocument === document) + " " + String(three.ownerDocument === document));

// --- Property-style updates, including a property named by a variable
const field = document.createElement("input") as HTMLInputElement;
field.value = "abc";
field.checked = true;
field.className = "named";
const name = "value";
// @ts-ignore: a property name a variable holds, as a renderer sets properties
field[name] = "dyn";
log("props " + field.value + " " + String(field.checked) + " " + field.className + " " + String(field.disabled));

// --- dataset: a live view of the data-* attributes, in the browser's camelCase
tree.dataset.fooBar = "baz";
tree.setAttribute("data-one-two", "3");
log("dataset " + tree.dataset.fooBar + " " + tree.dataset.oneTwo + " " + tree.getAttribute("data-foo-bar"));
delete tree.dataset.fooBar;
log("dataset gone " + String(tree.dataset.fooBar === undefined) + " " + String("oneTwo" in tree.dataset));

// --- cloneNode: attributes and inline style copy, children only when deep
const proto = document.createElement("div");
proto.id = "proto";
proto.setAttribute("title", "t");
proto.style.setProperty("color", "red");
const leaf = document.createTextNode("leaf");
proto.appendChild(leaf);
const shallow = proto.cloneNode() as Element;
const deep = proto.cloneNode(true) as Element;
log("clone shallow " + shallow.nodeName + " " + String(shallow.firstChild === null) + " " +
  shallow.getAttribute("title") + " " + proto.style.getPropertyValue("color") + "=" +
  shallow.style.getPropertyValue("color"));
log("clone deep " + String(deep !== proto) + " " + deep.childNodes.length + " " + deep.textContent +
  " " + String(deep.firstChild !== leaf) + " " + deep.id);

// --- innerHTML parses markup into real nodes, and serializes it back out
const host = document.createElement("div");
host.innerHTML = '<p class="lead">hi <b>there</b></p><!--note--><br>';
log("inner " + host.childNodes.length + " " + host.children.length + " [" + host.textContent + "]");
const bold = host.querySelector("b") as Element;
log("inner b " + bold.textContent + " in " + (bold.parentNode as Element).localName);
log("inner html [" + host.innerHTML + "]");
const ent = document.createElement("p");
ent.innerHTML = "a &amp; b &lt;c&gt; &#65;";
log("entities [" + ent.textContent + "] [" + ent.innerHTML + "]");
(host.querySelector(".lead") as Element).outerHTML = "<h2>lead</h2><i>i</i>";
log("outer " + host.childNodes.length + " [" + host.innerHTML + "]");
host.insertAdjacentHTML("afterbegin", "<s>start</s>");
host.insertAdjacentHTML("beforeend", "<u>end</u>");
const mid = document.createElement("em");
mid.textContent = "mid";
host.insertAdjacentElement("beforeend", mid);
host.insertAdjacentText("beforeend", "+txt");
log("adjacent [" + host.textContent + "] last=" + (host.lastChild as Node).nodeName);

// --- <template>: its children live in a content fragment, not in the tree
const holder = document.createElement("div");
holder.innerHTML = "<template><span>t</span></template>";
const tpl = holder.firstChild as HTMLTemplateElement;
log("template " + tpl.localName + " content=" + tpl.content.childNodes.length + " kids=" + tpl.childNodes.length +
  " html [" + tpl.innerHTML + "]");
tpl.content.appendChild(document.createTextNode("x"));
const tplCopy = tpl.cloneNode(true) as HTMLTemplateElement;
log("template clone " + tplCopy.content.childNodes.length + " [" + tplCopy.outerHTML + "]");

// --- MutationObserver: child list and attribute changes, delivered in a microtask
const watched = document.createElement("div");
const seen: string[] = [];
const observer = new MutationObserver((records) => {
  for (const r of records) {
    if (r.type === "attributes") seen.push("attr " + r.attributeName + " old=" + r.oldValue);
    else if (r.type === "childList") seen.push("kids +" + r.addedNodes.length + " -" + r.removedNodes.length);
    else seen.push("text [" + r.target.nodeValue + "] old=" + r.oldValue);
  }
});
observer.observe(watched, { childList: true, attributes: true, characterData: true, subtree: true, attributeOldValue: true, characterDataOldValue: true });
watched.setAttribute("data-k", "1");
watched.setAttribute("data-k", "2");
const watchedKid = document.createElement("span");
watchedKid.textContent = "k";
watched.appendChild(watchedKid);
(watchedKid.firstChild as Text).data = "kk";
watched.removeChild(watchedKid);
const scratch = new MutationObserver(() => { seen.push("should not run"); });
scratch.observe(watched, { attributes: true });
watched.setAttribute("data-k", "3");
const taken = scratch.takeRecords();
scratch.disconnect();
log("mutations taken " + taken.length + " " + (taken[0].attributeName as string));
Promise.resolve().then(() => {
  log("mutations [" + seen.join(",") + "]");
  observer.disconnect();
  watched.setAttribute("data-k", "4");
  Promise.resolve().then(() => log("mutations stopped " + seen.length));
});

// --- Elements built from markup and cloned get the page's rules too: no literal createElement
// names a section, so a tagged selector only reaches it through the parsed-markup case.
const host2 = document.getElementById("host") as HTMLElement;
host2.innerHTML = '<section class="box" id="a">x</section>';
const madeA = document.getElementById("a") as HTMLElement;
const madeB = madeA.cloneNode(true) as HTMLElement;
madeB.id = "b";
host2.appendChild(madeB);

// --- getBoundingClientRect reads the laid-out border box in viewport coordinates
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    const r = box.getBoundingClientRect();
    log("rect " + r.left + " " + r.top + " " + r.width + " " + r.height + " " + r.right + " " + r.bottom +
      " client " + box.clientLeft + " " + box.clientTop);
    const ra = madeA.getBoundingClientRect();
    const rb = madeB.getBoundingClientRect();
    log("parsed rect " + ra.width + "x" + ra.height + " clone " + rb.width + "x" + rb.height +
      " top " + ra.top + " " + rb.top);
  });
});

// --- Events: capture, target, once, passive, and bubbling to the document
const inner = document.createElement("button");
inner.id = "inner";
inner.textContent = "hit";
tree.appendChild(inner);
document.addEventListener("click", (e) => log("doc capture " + (e.currentTarget as Node).nodeName), true);
document.addEventListener("click", () => log("doc bubble"));
tree.addEventListener("click", (e) => log("tree capture target=" + (e.target as Node).nodeName), true);
tree.addEventListener("click", () => log("tree bubble"));
inner.addEventListener("click", (e) => log("inner target " + (e.currentTarget as Node).nodeName + " " + (e.target as Node).nodeName));
inner.addEventListener("click", () => log("inner once"), { once: true });
inner.addEventListener("click", (e) => {
  e.preventDefault();
  log("inner passive prevented=" + String(e.defaultPrevented));
}, { passive: true });
// Every element has the event handler properties, which a framework checks for ("onclick" in
// el) before it registers a listener, and a handler runs with the element as its receiver.
log("handler props " + String("onclick" in inner) + " " + String("onnothing" in inner));
inner.onclick = function (this: Node) { log("onclick this=" + String(this === inner)); };

// --- A promise, as a batched renderer commits, writes text that the next step reads
const late = document.createTextNode("");
paint.appendChild(late);
paint.addEventListener("click", () => {
  Promise.resolve().then(() => { late.data = "MMMM"; });
});
`;

// Steps: two clicks on #inner (the once listener mustn't run twice), then the paint click.
const STEPS = "frame | frame | click #inner | click #inner | click #paint | print #paint";

const EXPECTED_LOG = [
  "box first=#text text=AB n=1 elems=0",
  "box textContent=[AB]",
  "text nodeType=3 data=AB nodeValue=AB length=2",
  "element nodeType=1 nodeName=DIV localName=div nodeValue=null",
  "document nodeType=9 nodeName=#document",
  "instanceof true true true true false true",
  "tags [object HTMLDivElement] [object HTMLDocument] [object Event] [object TreeWalker]",
  "made text=3 #text [hi]",
  "made comment=8 #comment [note] true",
  "made fragment=11 #document-fragment true",
  "fragment holds 3 children",
  "inserted 3 nodes, 1 elements, fragment 0",
  "tree textContent=[1hi]",
  "first=SPAN last=#comment next=#text prev=#text",
  "elem siblings true true",
  "insertBefore one #text",
  "replaceChild true 3 DIV",
  "removeChild null 3 true",
  "data update textContent=[CD]",
  "data update text=[CD]",
  "fresh 1 #text [own]",
  "materialized 2 #text last= more [own more]",
  "attr 1 true",
  "removed attr true false",
  "boolean attr true",
  "namespace http://www.w3.org/2000/svg svg http://www.w3.org/1999/xhtml",
  "owner true true",
  "props dyn true named false",
  "dataset baz 3 baz",
  "dataset gone true true",
  "clone shallow DIV true t rgb(255, 0, 0)=rgb(255, 0, 0)",
  "clone deep true 1 leaf true proto",
  "inner 3 2 [hi there]",
  "inner b there in p",
  'inner html [<p class="lead">hi <b>there</b></p><!--note--><br>]',
  "entities [a & b <c> A] [a &amp; b &lt;c&gt; A]",
  "outer 4 [<h2>lead</h2><i>i</i><!--note--><br>]",
  "adjacent [startleadiendmid+txt] last=#text",
  "template template content=1 kids=0 html [<span>t</span>]",
  "template clone 2 [<template><span>t</span>x</template>]",
  "mutations taken 1 data-k",
  "handler props true false",
  "mutations [attr data-k old=null,attr data-k old=1,kids +1 -0,text [kk] old=k,kids +0 -1,attr data-k old=2]",
  "mutations stopped 6",
  "rect 0 20 200 20 200 40 client 0 0",
  "parsed rect 120x30 clone 120x30 top 100 130",
  "doc capture #document",
  "tree capture target=BUTTON",
  "inner target BUTTON BUTTON",
  "inner once",
  "inner passive prevented=false",
  "onclick this=true",
  "tree bubble",
  "doc bubble",
  "doc capture #document",
  "tree capture target=BUTTON",
  "inner target BUTTON BUTTON",
  "inner passive prevented=false",
  "onclick this=true",
  "tree bubble",
  "doc bubble",
  "doc capture #document",
  "doc bubble",
  "MMMM",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-dom-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: STEPS },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
const want = EXPECTED_LOG;
// Compare line by line so a mismatch names the first line that differs.
check(`log lines (${want.length})`, got.length === want.length, `got ${got.length}: ${JSON.stringify(got.slice(want.length))}`);
const n = Math.min(got.length, want.length);
for (let i = 0; i < n; i++) check(want[i], got[i] === want[i], `got ${JSON.stringify(got[i])}`);

// The promise's text is painted: white glyphs inside #paint's black box.
const img = decodePng(png);
let lit = 0;
for (let y = 0; y < 120; y++) {
  for (let x = 0; x < 400; x++) {
    const o = (y * img.w + x) * 4;
    if (img.rgba[o] > 200 && img.rgba[o + 1] > 200 && img.rgba[o + 2] > 200) lit++;
  }
}
check("text written in a microtask paints", lit > 100, `${lit} white pixels`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

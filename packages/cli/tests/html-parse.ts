// The HTML parser's document skeleton: a page whose markup is a bare <body> keeps that body for
// the content written after it, and a script after </body> is the body's — a browser's parser
// leaves "after body" mode for "in body" rather than building a second html with its own body.
//
//   node tests/html-parse.ts

import { parseHtml } from "../compiler/html.ts";
import { Diagnostics } from "../compiler/diagnostics.ts";
import type { HElement } from "../compiler/html.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

function elements(el: HElement, out: HElement[] = []): HElement[] {
  for (const c of el.children) {
    if (c.kind !== "element") continue;
    out.push(c);
    elements(c, out);
  }
  return out;
}

/** The tags of a parsed page, in document order, with the body's own children named. */
function shape(src: string): { tags: string[]; body: string[] } {
  const doc = parseHtml(src, "probe.html", new Diagnostics());
  const all = elements(doc);
  const body = all.find((e) => e.tag === "body");
  return {
    tags: all.map((e) => e.tag),
    body: body === undefined ? [] : body.children.map((c) => (c.kind === "element" ? c.tag : "[text]")),
  };
}

// A page written as a bare <body> with its script after </body>: the canvas stays in the body and
// the script joins it — one body, not a synthesized html>head beside an orphaned author body.
{
  const s = shape(`<!DOCTYPE html>
<body>
  <canvas id="canvas" width="100" height="100"></canvas>
</body>
<script>var x = 1;</script>
`);
  check("bare body keeps its content", s.body.includes("canvas"), s.body.join(","));
  check("a script after </body> is the body's", s.body.includes("script"), s.body.join(","));
  check("one body element", s.tags.filter((t) => t === "body").length === 1, s.tags.join(","));
  check("no stray head", !s.tags.includes("head"), s.tags.join(","));
}

// The same page with an explicit <html>: the canvas is the body's, and the trailing script goes
// where a browser puts it rather than into a head made after the body.
{
  const s = shape(`<!DOCTYPE html>
<html><body>
  <div id="box"></div>
</body></html>
<script>var x = 1;</script>
`);
  check("explicit html keeps its content", s.body.includes("div"), s.body.join(","));
  check("trailing script joins an explicit html's body", s.body.includes("script"), s.body.join(","));
  check("explicit html page has one body", s.tags.filter((t) => t === "body").length === 1, s.tags.join(","));
}

// White space after </body> is not content: it doesn't reopen the body or add a text box to it.
{
  const s = shape(`<!DOCTYPE html>
<body><p>x</p></body>

`);
  check("white space after </body> adds no body child", s.body.join(",") === "p", s.body.join(","));
  check("white space after </body> makes no second body", s.tags.filter((t) => t === "body").length === 1, s.tags.join(","));
}

// A second <body> merges into the first, as a browser merges it: one body, with both tags' attrs.
{
  const doc = parseHtml(`<!DOCTYPE html>
<body class="a"><p>x</p></body>
<body id="second"><p>y</p></body>
`, "probe.html", new Diagnostics());
  const bodies = elements(doc).filter((e) => e.tag === "body");
  check("a second <body> merges", bodies.length === 1, String(bodies.length));
  check("the merge keeps the second tag's attributes", bodies[0]?.attrs.get("id") === "second", bodies[0]?.attrs.get("id") ?? "none");
  check("the merge keeps both bodies' content", bodies[0]?.children.filter((c) => c.kind === "element").length === 2,
    String(bodies[0]?.children.filter((c) => c.kind === "element").length));
}

// Text after </body> is the body's, as a browser's parser keeps it.
{
  const s = shape(`<!DOCTYPE html>
<body><p>x</p></body>tail`);
  check("text after </body> is the body's", s.body.join(",") === "p,[text]", s.body.join(","));
}

// A page with no <body> at all still gets the skeleton, with its content in the implied body.
{
  const s = shape(`<!DOCTYPE html><div id="box"></div>`);
  check("content with no body implies one", s.body.includes("div"), s.body.join(","));
  check("implied body sits in a single html", s.tags.filter((t) => t === "html").length === 1, s.tags.join(","));
}

if (failed > 0) {
  console.error(`\n${failed} check(s) failed`);
  process.exit(1);
}
console.log("\nall checks passed");

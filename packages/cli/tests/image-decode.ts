// img.decode() and the decoding attribute: decode() resolves once the pixels are ready to paint
// and rejects for a source that can't be decoded, a load reports the size the file has, and the
// page paints the picture once it is decoded.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng, encodePng } from "./png.ts";

// The 2x2 fixture: red, green on the top row, blue, white on the bottom.
const CELLS = (x: number, y: number): number[] => {
  if (y === 0) return x === 0 ? [255, 0, 0] : [0, 255, 0];
  return x === 0 ? [0, 0, 255] : [255, 255, 255];
};

// The page reports every answer from the promise that is ready when it lands: the load event,
// decode(), the failure, and the state read before any of them settles.
const PAGE = `<!doctype html>
<html><head><title>Image decode</title>
<meta name="native-window" content="width=200, height=140">
<style>html, body { margin: 0; background: #ffffff; }
#shown { position: absolute; left: 0; top: 60px; width: 40px; height: 40px; }</style>
</head><body>
<img id="shown" src="quad.png">
<script><![CDATA[
  var img = new Image();
  var pending = 'pending ' + img.complete;
  img.src = 'quad.png';
  var loaded = new Promise(function (resolve) {
    img.onload = function () {
      resolve('load ' + img.complete + ' ' + img.naturalWidth + 'x' + img.naturalHeight);
    };
  });

  var dec = new Image();
  dec.src = 'quad.png';

  var bad = new Image();
  bad.src = 'missing.png';

  var hint = new Image();
  hint.setAttribute('decoding', 'async');

  Promise.all([
    loaded,
    dec.decode().then(function () { return 'decoded ' + dec.naturalWidth + 'x' + dec.naturalHeight; }),
    bad.decode().then(function () { return 'resolved'; }, function (e) {
      return 'rejected ' + String(e.message).split(':')[0];
    }),
    Promise.resolve('decoding ' + hint.decoding),
    Promise.resolve(pending)
  ]).then(function (parts) {
    for (var i = 0; i < parts.length; i++) console.log(parts[i]);
  });
]]></script>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-image-decode-"));
writeFileSync(join(dir, "quad.png"), encodePng(2, 2, CELLS));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) {
  console.error(b.stderr);
  process.exit(1);
}

const png = join(dir, "out.png");
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: {
    ...process.env,
    // The host may decode on a thread of its own; the wait lets the decodes land.
    NATIVE_STEPS: "wait 2000",
    NATIVE_SNAPSHOT: png,
  },
});
const got = r.stdout.split("\n").slice(0, -1);
// An image with no source is complete, as Chrome reports it; the line is logged before src is set.
const want = ["load true 2x2", "decoded 2x2", "rejected EncodingError", "decoding async", "pending true"];

let failed = 0;
const check = (name: string, ok: boolean, detail: string): void => {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : ` — ${detail}`}`);
};
check("load, decode() and the decoding attribute", r.status === 0 && JSON.stringify(got) === JSON.stringify(want),
  `got ${JSON.stringify(got)} (exit ${r.status})\n${r.stderr}`);

// The page paints the decoded picture: the four quadrants of the 40px image, at the backing scale.
const img = r.status === 0 ? decodePng(png) : null;
function at(cx: number, cy: number): number[] {
  const o = (Math.floor(cy * 2) * img!.w + Math.floor(cx * 2)) * 4;
  return [img!.rgba[o], img!.rgba[o + 1], img!.rgba[o + 2]];
}
// A 2x2 picture scaled up is filtered, so a sample at a quadrant's centre is that colour to a
// few counts rather than exactly as the file holds it.
const near = (got: number[], want: number[]): boolean => got.every((c, i) => Math.abs(c - want[i]) <= 24);
check("the decoded image paints", img !== null && near(at(10, 70), [255, 0, 0]) &&
  near(at(30, 70), [0, 255, 0]) && near(at(10, 90), [0, 0, 255]) &&
  near(at(30, 90), [255, 255, 255]),
  img === null ? "no snapshot" : `got ${at(10, 70)} ${at(30, 70)} ${at(10, 90)} ${at(30, 90)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

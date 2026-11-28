# Canvas GPU parity pages

`pages.ts` holds the pages the GPU canvas raster is held to, drawn in CSS px into a 200x150 canvas
with a 2x bitmap (400x300). `chrome/` holds headless Chrome screenshots of the same pages, taken at
a device pixel ratio of 2, so each screenshot is the canvas bitmap pixel for pixel.

`tests/canvas-gpu-parity.ts` builds each page as an app and snapshots it composited with
`NATIVE_GPU_CANVAS=1` and with `NATIVE_GPU_CANVAS=0`, and diffs both against the screenshot.

To take the screenshots again, write the Chrome copies of the pages and screenshot them with
Puppeteer at `width=200, height=150, deviceScaleFactor=2`, clipping to the page:

```js
const { writeChromePages } = await import("./pages.ts");
writeChromePages(out);
const page = await browser.newPage();
await page.setViewport({ width: 200, height: 150, deviceScaleFactor: 2 });
await page.goto("file://" + out + "/chrome/circle.html");
await page.screenshot({ path: "chrome/circle.png", clip: { x: 0, y: 0, width: 200, height: 150 } });
```

The screenshots in this directory came from Chrome 158 on Linux. Chrome writes them as 8-bit RGB
(colour type 2); they were re-encoded as 8-bit RGBA (colour type 6), which is what `tests/png.ts`
reads.

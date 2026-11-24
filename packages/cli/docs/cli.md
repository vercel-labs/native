# CLI reference

Run the CLI with `node compiler/cli.ts <command>` (shown as `native` below).

## Commands

- `native build <dir> [-o out] [--release]`: compile to a self-contained app bundle
- `native run <dir> [--release]`: build, then run
- `native dev <dir> [-o out] [--inspect[=port]] [--compiled]`: watch the app, applying edits as they are saved, with a dev inspector on a local port (`--compiled` rebuilds and relaunches on every script edit instead of rerunning the scripts in the dev host)
- `native check <dir>`: diagnostics only
- `native wpt <fetch|run>`: run web-platform-tests; see [wpt.md](wpt.md)

A release build is linked without the symbol table and debug info the linker would otherwise keep, which no app reads at run time. A dev build keeps both, so a debugger can break in the app.

## The compiler

A build compiles the TypeScript with scriptc: the copy `pnpm install` put in `node_modules`, or the
platform package's own binary when the install script was skipped. Set `NATIVE_SCRIPTC` to a path
to compile with another one — a checkout of [scriptc](https://scriptc.dev) or a build of it — without
installing it over the project:

```console
$ NATIVE_SCRIPTC=~/src/scriptc/bin/scriptc.exe native build . -o build/app
```

A checkout of scriptc has to be built first, and its LLVM helper and runtime pack along with it; see
its own `CONTRIBUTING.md` for the steps.

The compiler's frontend runs in a JavaScript heap the build sizes to the machine — most of its
memory, up to 8 GB, and never less than Node's own default — so a large app, such as a React
component library's page, compiles without one. A `--max-old-space-size` already in `NODE_OPTIONS`
is kept as it is.

## Build progress

A build is a compile of the whole SDK runtime, so on a large app it can take minutes. While it
runs it names the step it is in — resolving modules, compiling TypeScript, generating code,
optimizing code, linking, packaging the app — and how long that step took. In a terminal the
current step is drawn live with a spinner and its elapsed time, and once the same output has been
built before, the line carries an estimate of how far through the compile it is. When the output is
a pipe or a CI log the build prints one line per step instead, so the log says where the build is
without being redrawn. The one-time dev host build in `native dev` reports the same steps; the
edits that follow in a session are short enough to report only their own timing.

## Bundles

A built app carries the files it reads. `native build . -o hello` writes an app bundle, and the
output runs after it is moved and the app's source is deleted:

- On macOS the bundle is `hello.app`: the executable is `hello.app/Contents/MacOS/hello`, its files
  are in `hello.app/Contents/Resources`, and an `Info.plist` makes it an app Finder can open. The
  path given with `-o` stays a way to run the app (a hard link to the same executable).
- On other platforms the executable is written at the given path with a `hello.resources` directory
  beside it.

The bundle keeps the layout the app had: an image at `img/a.png` is `Resources/img/a.png`, so a
page-relative URL names the same file at runtime. Images (markup, `srcset`, CSS `url()`, inline
styles, `data:` URLs), `@font-face` files, linked and imported style sheets, and the files scripts
name with a literal `fetch()` or import are copied. The bundle also holds `.native/page.json`, the
compiled page and style tables the runtime reads at startup; the executable carries no tables of
its own, so an edit to the markup or styles is a single file's rewrite (see
[Build cache](#build-cache)). A dev build (`native dev`) keeps the source paths and copies nothing,
which keeps rebuilds fast.

### The public directory

Files the build can't see a reference to travel in a `public` directory beside the page. Everything
under `public/` is copied into the bundle as it is, at the app's root: `public/covers/a.png` is
`Resources/covers/a.png` (or `a.resources/covers/a.png`), and a URL a script builds at run time
names it:

```ts
const cover = document.getElementById("cover") as HTMLImageElement;
cover.src = "/covers/" + track.cover;      // track.cover is "a.png"
```

A `/` URL is the site root, so `/covers/a.png` is a public file, and so is a URL with no leading
slash (the page is at the root). This is the convention the web's build tools use (`public/` in
Vite, Create React App and Next.js), and the way to ship a data-driven app's images, audio and
other files. A public directory is copied whole, whether or not anything names a file in it; a file
kept anywhere else still travels when a script fetches a literal URL or imports it, as above.
`native dev` serves `public/` at the root too.


## App identity

Every bundled build (`native build`, `native run`, released or not) names the app from its own
page: the bundle carries the app's name, identifier, version and icon, and the macOS `Info.plist`
and the app menu describe the app Finder and Launch Services see. A release build's executable is
the same program a plain build makes — the identity is data in the bundle — so a plain build and a
release build of one app share the build cache, and editing the identity needs no recompile.

The facts come from the page, the way a browser reads them:

- A web app manifest the page links with `<link rel="manifest" href="…">`. Its `name` and
  `short_name` name the app, its `id` is the bundle identifier when it is a string macOS accepts
  (letters, digits, periods and hyphens, as in `dev.example.notes`), and its `version` is the
  app's version. Its `icons` give the icon, the largest PNG first; `sizes` is used when the image
  can't be measured. A `update_url` in the manifest turns on the app's update check.
- Without a manifest, the page's `<title>` is the name and `<link rel="icon">` (with `sizes` and
  `type`) gives the icon. Without an icon, the bundle has none.
- Without either, a `productName` (or the scope-less `name`) in a `package.json` beside the page
  names the app, and the app's directory name is the last resort.
- `NATIVE_APP_ID` and `NATIVE_APP_VERSION` override the manifest, so a release pipeline can name
  and version a build without editing the app.

The identifier is `NATIVE_APP_ID`, then the manifest's `id`, then `dev.native-sdk.<name>` made
from the display name. On macOS the display name is the app menu's ("About Tide", "Quit Tide") and
`CFBundleName`, and the identifier is `CFBundleIdentifier`.

The bundle gets `.native/app.json` (the same facts, with the icon at `.native/icon.png`) and the
platform's packaging reads it. On macOS the icon becomes `Contents/Resources/AppIcon.icns` with
the system's `sips` and `iconutil`, and the `Info.plist` names it with `CFBundleIconFile`. A
manifest that can't be read, or an icon file that isn't there, prints one warning and the build
goes on with what it has.

On macOS a release build is also signed and packaged; [Shipping a macOS app](macos.md) covers the
identity and notary environment variables, the `.dmg`, and how to check a build.

## Platforms

A build links one native host: the windowed host on macOS, the Win32 host on Windows, or the
headless Linux host (the same one `native wpt` uses). The host is compiled for the machine the CLI
runs on. On Windows that means `zig` on the `PATH` — scriptc links a Windows app with `zig cc` for
the GNU target, and the host object has to come from the same toolchain — and the app is linked as a
GUI program, so no console window opens behind it. The executable is written at the given path with its `.exe` name and
its files in `<executable>.resources` beside it.

A Windows app can also be cross-built from Linux or macOS. That needs `zig` on the `PATH`, the
target's scriptc packs installed in the project (their `os` field is Windows-only, so npm needs
`--force`), `SCRIPTC_TARGET` naming the target for scriptc and for the host's compiler, and, for
WebGL 2, `NATIVE_ANGLE_DIR` naming an ANGLE build: the CLI's own one is packaged for Windows x64,
so npm does not install it on the machine doing the cross-build.

```console
$ npm install --force @scriptc/runtime-win32-x64-msvc@0.4.14 @scriptc/llvm-win32-x64-msvc@0.4.14
$ SCRIPTC_TARGET=x86_64-windows-gnu node compiler/cli.ts build examples/counter -o build/counter
```

It writes `build/counter.exe`, a PE32+ program that needs no console.

The pack versions match the installed `scriptc`. The Windows host draws the page's display list
(fills, borders, rounded corners, clips, gradients, images, text, shadows and a box's filter chain)
and canvas 2D, and publishes the page's accessibility tree through UI Automation; it has no
input-method composition and does not apply backdrop filters or `mix-blend-mode`.

WebGL 2 runs on ANGLE, which the host loads at run time: the copies in the app's own
`<executable>.resources` first, then those in `NATIVE_ANGLE_DIR`, then the system's. Every Windows
build copies `libEGL.dll`, `libGLESv2.dll` and `d3dcompiler_47.dll` into the app's resources from
the `@native-sdk/angle-win32-x64` package, an optional dependency of `@native-sdk/cli` that npm
installs on Windows x64, so the app carries WebGL 2 with it and the machine it runs on needs no
ANGLE. Set `NATIVE_ANGLE_DIR` to build with another ANGLE build instead. Where the libraries are
found nowhere, `getContext("webgl2")` answers null after firing `webglcontextcreationerror`, as a
browser without WebGL does.


## JSX

An app's sources may be `.tsx` or `.jsx`, named by the page's `<script type="module" src="app.tsx">` or imported from another of the app's files, and `native` builds them like `.ts` ones. The JSX mode comes from the app's own `tsconfig.json`: `jsx` (`react-jsx`, the default when there's no tsconfig, or `react` for the classic factory), `jsxImportSource` (`react` by default), and `jsxFactory`/`jsxFragmentFactory` for the classic runtime. The runtime's package has to be installed in the app's `node_modules`, next to any other dependency: `native` compiles it with the app, so the imports its transform writes into each JSX file and the app's own imports reach one copy of the runtime (Preact's `preact/jsx-runtime` works; a second copy would have its own fragments and hooks). Its type declarations are read the way TypeScript reads them, from the package itself or from the `@types` package installed for it, as React's are. A dev build asks for `jsx-dev-runtime` when the package ships one, so a debugger sees `jsxDEV` calls. With the classic runtime the JSX types come from the package the app imports `jsxFactory` from, the way TypeScript finds them, so a Preact app written with `h()` needs no extra setting. A per-file `@jsxImportSource` pragma isn't honored; put the setting in the tsconfig. The JSX settings are the only type options a JSX build takes from the app's tsconfig: `native` writes `.native/tsconfig.json` beside the copied sources, so an app's `lib` doesn't reach the compiler from there, and the DOM names a page and its dependencies use come from the runtime instead of `lib.dom.d.ts` (see [how-it-works.md](how-it-works.md)). A build without JSX has no generated tsconfig, and leaves the app's own one for the compiler to read.
A name a source uses only as a type — an annotation, a cast, a generic argument, a union — is left to the type world the build checks against when that world is a browser's, so it is the same type a dependency's declarations name: a Preact app's `Ref<HTMLDialogElement>` and the ref callback the page writes are one type, and `event.target as HTMLInputElement` is the browser's `HTMLInputElement` when a dependency's declarations reference `lib.dom`. A build whose global names are the runtime's own keeps the import for such a name: those globals are interfaces with no method body, and a call through one doesn't compile. A name a source uses as a value — `instanceof`, `new`, `document`, a call — is always the runtime's own class or object.

## Live editing

`native dev` watches the app's directory and runs the app's scripts in the dev host: a compiled executable holding the whole SDK runtime and no app code, built once per SDK version and shared by every app on the machine. A published CLI ships that host prebuilt in the optional package for the machine's platform (`@native-sdk/dev-host-<platform>`, built by the release workflow); when the package's SDK digest matches the CLI's own sources, `native dev` runs it at once. A checkout, a modified SDK, an unsupported platform or a missing package builds the host the first time instead, with the same result. A TypeScript edit is rebundled and rerun in the page that is already open, without relaunching the window, and the command prints how long it took from the change to the host's acknowledgement of the new bundle. An HTML or CSS edit recompiles the page's tables and applies them to the window that is already open: nodes that stayed in the markup keep their identity, so listeners, input values and other script state survive. A script edit re-mounts the page from the new tables, restores form values, scroll positions and focus, and clears the timers the previous bundle left running. A build error prints in the terminal, the session keeps watching, and a broken script doesn't stop HTML/CSS edits from reloading into the window that is already up.

In `native dev`, the app's scripts run on Node's JavaScript engine against the compiled DOM. `native build` compiles them, so a difference between the two shows up where the compiler refuses or documents a limitation, and as a DOM call from a script costing a few microseconds rather than a direct call. `native dev --compiled` builds the app with scriptc's `dev` optimization and relaunches the executable on every script edit instead, carrying input values (an input, textarea or select), scroll positions, focus and the caret over and naming the modules an edit changed. When the new process paints its first frame it writes `.native/dev-ready`; the dev command reads that and prints the whole wait, for example `edit→screen 1320ms (native+scriptc 1200ms, launch+first frame 120ms)`. A dev build compiles scriptc's LLVM partitions on every core the machine has, since the window is waiting on the rebuild; a rebuild whose inputs match the last one takes the executable from the build cache instead of compiling. Island reloading needs the `@scriptc/libnode-<platform>` pack and Node.js 24.13.1 or later; without the pack, `native dev` prints one line and uses the compiled path.

The island runs the app under scriptc's Node.js load hook: an import of a builtin module the compiler refuses, and a native addon, fail in dev with the diagnostic a build reports (`SC1010`, `SC2020`), and `eval`, `Function` and a function's `constructor` throw the `EvalError` a compiled program throws. A direct `eval()` call in the app's code reaches the engine's own intrinsic and cannot be intercepted in this process; scriptc refuses those at build time. After each rebuild the command also runs `scriptc coverage` on the app in the background — the app's own files, typed with the runtime's DOM declarations — and prints any finding it adds, then lists them in a panel over the page until a later clean edit clears it. The reload never waits for that check. Coverage reads the code without running it, so it cannot see a refusal that depends on a run-time value; a compiled build (or `native dev --compiled`) is still the check for those.

An exception that no script catches prints against the files the app's author wrote, not the build's copies: a dev build maps a stack frame in `.native/src` back to `app.ts` (or a dependency's own file) with its own line and column, maps an inline script to its line in `index.html`, and leaves the SDK's internal frames out. The window keeps running after a handler throws, as a browser's page does, so the next event still reaches the page. The lines come from the dev build's source tables; a release build, which strips them, names only the file.

## Inspector

`native dev --inspect` serves a browser-devtools-style inspector for the running app on
`http://127.0.0.1:9229/`; `--inspect=PORT` chooses another port, and `--inspect=0` asks the system
for one. It shows the page's DOM tree, the computed styles and box model of the selected node, the
layers the renderer paints (each with the property that gives it a layer, and its z-index), the
frame times of the last 240 frames, and everything the app prints. The console also evaluates
read-only expressions against the last snapshot: `document.querySelector('.item').textContent`,
`getComputedStyle(document.body).getPropertyValue('font-size')`.

The page and a Chrome DevTools Protocol subset come from the same server, so a DevTools client can
attach to the app: `/json/version`, `/json/list` and `/json/protocol` describe the page, and
`/devtools/page/native` is a WebSocket that speaks `DOM.getDocument`, `DOM.querySelector`,
`DOM.describeNode`, `DOM.getBoxModel`, `CSS.getComputedStyleForNode`, `Overlay.highlightNode`,
`Overlay.hideHighlight`, `Page.captureScreenshot`, `Page.getFrameTree`, `Runtime.enable`,
`Runtime.evaluate`, `Runtime.consoleAPICalled`, `Runtime.exceptionThrown` and `Log.entryAdded`, plus
`Native.getSnapshot`, `Native.getLayers` and `Native.getFrameTimes` for the inspector's own panels.
Selecting a node highlights its box in the app; a screenshot comes back as a PNG.

The app answers over `.native/.inspect`: a dev build polls that directory and writes the snapshot the
server asked for. None of it is compiled into a release build, and the server binds to the loopback
interface only.

## Build cache

Every input a build reads is hashed: the app's files, the runtime and shared sources, the host, the installed dependencies' names, sizes and modification times, the compiler and scriptc versions, and the environment variables the build reads. A build whose hashes all match one an earlier build stored copies that build's executable into place instead of running scriptc, and reports `scriptc cached`. The entry also holds the page tables a release build reads from its bundle, the tables for a dev build, the warnings the build printed, and a manifest of every module with its content hash. The manifest is what `native dev` reads to name the modules an edit changed, and a build whose vendored dependency changed still misses, because the program's key covers every copied and generated module.

A release build's page tables are data in the bundle, not part of the program, so a build also remembers the program each executable was built from. When an edit leaves that program byte for byte the same, `native build` writes the new tables and the app's files beside the executable it already has and reports `scriptc skipped`. That covers an edit to the markup or styles, and it works without the cache too (the record lives in `.native/builds.json`). A change to the app's scripts, or to generated code the markup decides (an inline handler's element index, a script's order), is a new program and compiles.

What the cache and that record cannot do is compile only part of a program: scriptc has no per-module compilation cache yet, and `native` cannot split a native program into separately compiled and linked modules. So an edit to one app module, or to one file in a dependency, still needs a full compile. What they remove is the repeated work around an unchanged program: the daily no-change rebuild, an edit that is reverted, a checkout whose inputs match another build's, CI jobs that rebuild the same app, and every markup or style edit.

The cache lives in `$NATIVE_CACHE_DIR`, else `$XDG_CACHE_HOME/native/build` (or `~/.cache/native/build`). `NATIVE_NO_CACHE=1` bypasses it, and `NATIVE_CACHE_MAX_MB` caps its size (4096 MB by default), with the least recently used entries removed first. Each build also writes `.native/modules.json`, the manifest of every module and its hash that `native dev` reads.

## Headless runs

Useful for tests and CI. Steps go through the same pointer and keyboard paths as real input:

```console
$ NATIVE_STEPS='click #new | type Buy milk | key Enter | hover .item | print #left' \
  NATIVE_SNAPSHOT=out.png ./build/todo
1 item left
```

Steps are `click <sel>`, `hover <sel>`, `type <text>`, `compose <text>` (an input method reports the marked text it has composed), `commit <text>` (the input method commits that text) and `cancelcompose` (it abandons the composition), `key [Meta+|Shift+|Alt+|Ctrl+]<Enter|Backspace|ArrowLeft|…|SelectAll|Copy|Cut|Paste>` (a press and a release), `keydown`, `keyrepeat` and `keyup <key>` (the three steps on their own, so a held key's repeat is a `keyrepeat`), `drag <sel> <dx> <dy>` (a press that moves, which a `draggable` element turns into a drag), `dropfiles <sel> <path>[,<path>…]` (files dragged in from outside the app and dropped on the element, as a drop from the Finder arrives), `wheel <sel> <dy> [dx]` (positive `dy` scrolls down, positive `dx` scrolls right), `print <sel>`, `scrolltop <sel>`, `scrollleft <sel>`, `frame [ms]` (runs the animation callbacks queued for the next frame, with that timestamp), `resize <width> <height>` and `wait <ms>` (pauses that long, letting the app's timers, promises and network requests finish). The app shell's own events have steps too: `menu` prints the menu bar the page's markup built, one item per line; `menuclick <path>` chooses an item by its path (`Edit/Copy` walks into the Edit menu for the Copy item); `contextmenu <sel>` is a right-click at the element's centre; and `focus`, `blur`, `hide`, `show`, `title`, `message <id> <json>` and `quit` are the window's and the app's events, `message` arriving with that window's id as its source. Between steps the runner lets queued microtasks and timers settle, so a renderer that batches its updates (as Preact does) is on screen before the next step; work a renderer schedules for the next animation frame, such as Preact's `useEffect`, runs on the next `frame` step. A snapshot is taken after the last step, and `requestAnimationFrame` callbacks only run on a `frame` step, so an app that draws from its frame loop (a canvas, an animation) needs one or more before the snapshot: `NATIVE_STEPS='frame 0 | frame 800'`. `pnpm test` builds the examples and checks scripted flows this way.

`NATIVE_SNAPSHOT` is optional: with `NATIVE_STEPS` alone the app still runs the
steps headlessly, prints what they print, and exits with status 0 after the last
one, so a CI job that only checks output doesn't leave a window up.

`NATIVE_FRAME_TIMES=1` makes every frame print the time its stages took on stderr:
`native: frame 12 t=142.6 style=0.03 anim=0.2 layout=9.6 shape=2.1 paint=15.4 layers=3 total=25.4`. The
stages are the restyle, the animation tick, layout and the paint walk (its host
calls included), and `total` is the whole frame. `t` is how far into the run the frame was
painted, so the first frame line's `t` is the first paint. The macOS host also prints the
time it spent compositing each frame — or, for a frame the compositor leaves to the
window's replay, its replay and present times — and, once, the text antialiasing and
colour space the window's context draws text with. The timings are for benchmarks,
so they cost nothing unless the variable is set. A frame line also carries `shape=`, the
milliseconds the host spent shaping text since the previous line, which layout waits on: the share
a text pre-shaping thread would take.

Incremental layout is on by default; `NATIVE_INCREMENTAL_LAYOUT=0` turns it off. A box whose
inputs and content haven't changed since its last layout keeps that layout, and a change inside a
box whose size it can't affect lays out that box alone. With `NATIVE_FRAME_TIMES`, the frame line's
`laidOut=` counts the boxes laid out and `cached=` the layouts reused. `NATIVE_VERIFY_INCREMENTAL=1`
lays every frame out a second time from scratch, printing a `native: layout mismatch:` line for
each box the two disagree on (and `mismatches=` on the frame line); `NATIVE_VERIFY_LOG=<dir>` also
writes them to a file in that directory. A headless run can switch with the
`layout incremental|full|verify` step. `pnpm --filter @native-sdk/cli wpt:verify-incremental
[dir...]` runs WPT that way over the directories incremental layout is checked against
(positioning, cssom-view, display, tables, flex, grid, normal flow) and fails on any mismatch; the
`wpt-incremental` workflow runs it nightly.

`NATIVE_DAMAGE=0` turns damage-limited painting off. With the compositor off, a frame that only
changed some boxes records just the rectangles those boxes painted (the union of their old and new
bounds), clipped, and the paint walk skips boxes whose recorded ink misses every rectangle; the
window keeps the rest of its backing. A resize, a scroll, a full layout pass or a backdrop filter
still paints the whole page. `NATIVE_VERIFY_DAMAGE=1` paints a full frame as well and replays the
damaged list over it, printing `native: damage verify mismatched=<n> rects=<n> frame=<n>` (the
pixels that differ inside the damage rectangles, and across the whole frame, where a nonzero count
outside them is stale paint the damage missed); `NATIVE_DAMAGE_STATS=1`
prints `native: damage limited=<0|1> rects=<n> reason=<why>` beside each frame line.

On macOS the window's frames are composited: the paint's layers are rastered into
tiles that stay as textures, and a frame that only moves a transform or an opacity
draws them again without touching CoreGraphics. Tiles are kept by what they show — a
hash of the chunk's commands and the state its raster bakes in — so a chunk whose
commands only moved to other indexes in a new paint keeps its tiles. A layer that holds layers or
transforms of its own is split into chunks of its own runs, as if its commands stood in the page,
so an unchanged layer inside it keeps its tiles while a sibling animates. A chunk with no
matching tiles is rastered in the frame that draws it, across the raster pool, so every
frame holds every chunk of its paint; `NATIVE_RASTER_WORKERS=0` keeps every raster on
the main thread, `NATIVE_IMAGE_WORKERS=0` decodes images at load on the thread that asks
instead of on the decode pool, `NATIVE_COMPOSITOR=0` leaves the window to the AppKit replay, and
`NATIVE_COMPOSITOR_STATS=1` prints what each frame drew
(`native: composite chunks=200 tiles=144 kept=198 rastered=2 keyless=0 rasterms=1.2 …`).
A canvas is a chunk of its own that the window draws from a texture instead of rastering:
a 2D canvas's bitmap is copied into a texture only when the canvas changed, and a WebGL canvas
presents into IOSurfaces that GL draws into and the compositor samples directly, so a WebGL
frame is never read back or premultiplied on the CPU (the canvas bitmap is filled from the
surface only when a CoreGraphics raster needs it, such as a snapshot). `NATIVE_GL_SURFACE=0`
reads every WebGL frame back into the bitmap instead, and `NATIVE_CANVAS_TEXTURE=0` rasters
every canvas into its chunk.
`NATIVE_COMPOSITOR_LIVE=1` makes a headless macOS run composite every frame it presents
through the window's path into a texture, and a composited snapshot (or the
`snapshotcomposited <file>` step, which writes it without a paint first) reads that frame
back; `tests/compositor-live.ts` holds it to the flat replay. `NATIVE_PRESENT_STATS=1` reads
every frame the presenter hands the drawable back from the GPU and prints
`native: present <w>x<h> colours=<n>`, its device size and how many distinct colours it holds, so
a test can check that a window is still drawing its page after a change and not only the page's
background; `tests/window-resize-paint.ts` uses it.

On Windows the same chunk walk runs over the Direct2D display list: each chunk is rastered once
through Direct2D into a texture on the hardware D3D11 device, the textures are kept, and the
window composites them and presents on its flip-model swap chain. The Windows walk is a grouped
one: a subtree the chunks can't carry across their quads (a filter, a mask, a projection, a
rotated or shaped clip) is rastered as one chunk with its state in it, and an opacity group that
spans several chunks is one chunk faded when it is drawn, so such a page is still composited
rather than replayed flat. A chunk whose transform changes from frame to frame (an animated
translate, scale or rotate) is drawn from the texture it already has through the new transform,
sampled; once a frame finds it where the last one drew it, it is rastered again where it stands,
and a window that has been still for a quarter second composites once more so every chunk is
exact. The compositor is on by default; `NATIVE_COMPOSITOR=0` turns it off and leaves the window to
the flat Direct2D replay. `NATIVE_COMPOSITOR_STATS=1` prints what each frame kept, rastered and
resampled, with where its time went (`native: composite chunks=28 tiles=28 kept=24 rastered=4
keyless=0 rasterms=7.3 … resampled=10 walkms=0.3 drawms=0.04 presentms=0.5 ms=9.1`), and
`NATIVE_COMPOSITOR_STATS=2` also prints every chunk it rastered. A composited snapshot
(`NATIVE_SNAPSHOT_COMPOSITED`) is built through the same path, with every chunk rastered where it
stands. With `NATIVE_FRAME_TIMES`, the Windows host's `native: present` line carries `at=`, when the
frame was presented on the host's high-resolution clock, since the runtime's `t=` comes from a
timer that ticks every 15.6 ms there.

Box shadows and blurred text shadows on Windows are blurred on the device with Direct2D's shadow
effect, so a shadow never reads the frame back to the CPU; `NATIVE_CPU_BLUR=1` uses the CPU blur
instead.
`NATIVE_SNAPSHOT_COMPOSITED=<file>` writes the same frame built from its layers: each layer's
commands are rastered on their own and composited where the page painted them, instead of the
flat replay `NATIVE_SNAPSHOT` writes. Both may be set in one run. On Linux the two must match
wherever a raster can't resample — a layer at rest, or one moved by whole device pixels — which
is what `tests/compositor-exact.ts` checks. On macOS the same snapshot draws every layer from the
raster the window path keeps for it.

`NATIVE_PASTEBOARD=<file>` keeps the run's clipboard in that file rather than the
system pasteboard: a copy writes it and a paste reads it, so a headless test
never touches the user's own clipboard, and two runs at once don't race. The
file holds `text/plain`, and the markup a copy carries is the file beside it
with `.html` on the end. The Linux host has no window of its own to own an X11
or Wayland selection, so it keeps its clipboard in the same two files, named
after the user's runtime directory unless `NATIVE_PASTEBOARD` says otherwise.

`NATIVE_MENU_CHOICE=<line>` makes a headless run choose that line of every context menu it shows.
A window opened by `window.open()` is a process of its own, so a test opens one by running the
binary with `NATIVE_WINDOW_URL` (its route), `NATIVE_WINDOW_NAME` (the name a link's target gave it)
and `NATIVE_WINDOW_OPENER` (the id of the window that opened it).

`NATIVE_TARGET_TEXT=<directive>` opens the app with a text fragment, the value a
URL's `#:~:text=` carries — `[prefix-,]start[,end][,-suffix]`, with percent
escapes decoded. The first match, ASCII case-insensitively, paints as
`::target-text` says: its `background-color` and `color`, or the browser's pale
yellow when the page gives no rule.

## Window

Set the window's initial size in the page's `<head>`:

```html
<meta name="native-window" content="width=420, height=480">
```

The same tag takes `min-width`, `min-height`, `resizable=no` and a `titlebar` style:

- `default`: the standard macOS titlebar.
- `hidden`: the page draws to the top edge, under a transparent titlebar, with the traffic lights over it.
- `hidden-inset`: the same, with a taller bar and the traffic lights set in, as in an app with its own toolbar.
- `transparent`: like `hidden`, keeping the window title.

A page that draws into the titlebar lays out around the traffic lights with
`env(titlebar-area-x)`, `env(titlebar-area-y)`, `env(titlebar-area-width)`, `env(titlebar-area-height)`
and `env(safe-area-inset-top)`, and marks the areas that drag the window with `app-region: drag`
(`no-drag` keeps a control inside one clickable). Double-clicking a drag area zooms the window. These are the
names the web's Window Controls Overlay uses:

```html
<meta name="native-window" content="width=1100, height=680, titlebar=hidden-inset, min-width=760">
<style>
  .toolbar { height: env(titlebar-area-height, 40px); padding-left: env(titlebar-area-x, 0px); app-region: drag; }
  .toolbar button { app-region: no-drag; }
</style>
```

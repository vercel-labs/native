# Native SDK

<p>
  <a href="https://vercel.com/labs#active-experiments"><img alt="Vercel Labs Experiment" src="https://img.shields.io/badge/LABS-EXPERIMENT-0a0a0a.svg?style=for-the-badge&amp;logo=Vercel&amp;labelColor=000000" height="28"></a>
  <a href="https://www.npmjs.com/package/@native-sdk/cli"><img alt="npm version: @native-sdk/cli" src="https://img.shields.io/npm/v/%40native-sdk%2Fcli.svg?style=for-the-badge&amp;labelColor=000000" height="28"></a>
  <a href="https://github.com/vercel-labs/native/blob/next/LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/github/license/vercel-labs/native.svg?style=for-the-badge&amp;labelColor=000000" height="28"></a>
  <a href="https://www.npmjs.com/package/@native-sdk/cli"><img alt="npm downloads per month: @native-sdk/cli" src="https://img.shields.io/npm/dm/%40native-sdk%2Fcli.svg?style=for-the-badge&amp;labelColor=000000&amp;label=npm%20downloads" height="28"></a>
</p>

HTML, CSS and TypeScript compiled into native apps, without Node.js. Native SDK's compiler, the `native` CLI, compiles the HTML and CSS ahead of time, and [scriptc](https://scriptc.dev) compiles the TypeScript, both your app's and the SDK's runtime, to machine code. The result is a small native app bundle — an executable with the images, fonts and other files it reads — that runs without a browser, webview or JavaScript engine.

Native SDK is experimental and supports a subset of HTML, CSS and the DOM. Run `native check` on an app to see what it uses that isn't supported, and see [supported features](packages/cli/docs/supported.md) for details. It builds on macOS, Linux and Windows: the windowed host on macOS, the Win32 host on Windows, and the same pages run headlessly on Linux for the web-platform tests.

## Installation

Install with Node.js 24 or later. On macOS the Xcode command line tools provide the compiler (`xcode-select --install`); on Linux, [shipping a Linux app](packages/cli/docs/linux.md) lists the host libraries and the packaging tools; and on Windows `zig` on the PATH builds both scriptc's link and the Win32 host. The web-platform tests build the headless Linux host and need the libraries listed in [cli.md](packages/cli/docs/cli.md).

Add the CLI to an app with npm and run it from a `package.json` script:

```console
$ npm install --save-dev @native-sdk/cli
```

```json
{
  "scripts": {
    "build": "native build . -o build/hello",
    "dev": "native dev ."
  }
}
```

`npx @native-sdk/cli build .` runs the same CLI without installing it. The package named `native` on npm is unrelated, so don't write `npx native`.

To work on Native SDK itself, clone the repository and install the workspace:

```console
$ git clone https://github.com/vercel-labs/native.git
$ cd native
$ pnpm install
```

The repository is a pnpm workspace: the CLI is `packages/cli`, the docs site `apps/docs`, and each app under `examples/` is a package of its own. `pnpm build` builds the CLI, the examples and the docs site through Turborepo, `pnpm test` runs the test suite, and `pnpm test:examples` builds and launches every example.

An app is a directory of its own and doesn't have to live in this repository. The examples below run the CLI from a checkout as `node packages/cli/compiler/cli.ts`, or as `native` from the app's `package.json` script.

## Build an app

An app is an HTML page with its stylesheets and scripts. Create `index.html`:

```html
<!doctype html>
<html>
  <head>
    <title>Hello</title>
    <link rel="stylesheet" href="style.css">
  </head>
  <body>
    <h1 id="greeting">Hello</h1>
    <button id="wave">Wave</button>
    <script type="module" src="app.ts"></script>
  </body>
</html>
```

`style.css`:

```css
body { font-size: 18px; }
h1 { color: #4338ca; }
```

`app.ts`:

```ts
const greeting = document.getElementById("greeting")!;
document.getElementById("wave")!.addEventListener("click", () => {
  greeting.textContent = "Hello, native";
});
```

`native build` writes a self-contained app bundle: on macOS `hello.app`, with its images, fonts
and other files in `Contents/Resources`, and elsewhere the executable `hello` with a
`hello.resources` directory beside it. Files a script names at run time — a cover image, a track —
go in a `public` directory beside the page: the build copies it into the app's root as it is, and a
URL built in code names them. The build's output path is still a way to run the app:

```console
$ node packages/cli/compiler/cli.ts build . -o hello
$ ./hello
```

`native run` builds and runs in one step. `native dev` watches the app and applies HTML and CSS edits to the open window in place; a TypeScript edit rebuilds and relaunches it, keeping what state it can. The [examples](examples) are a counter; a todo list; an article with inline formatting and a link; a dashboard with a sidebar, stat cards and a members table; an animated canvas piece; a canvas particle field; a spinning WebGL 2 cube; a WebGL 2 texture uploaded from a file; a `@keyframes` and transition piece; a todo list in Preact; an input method composing marked text in a field; a playable three.js game; a lit three.js hero scene; a React 19 and Tailwind 4 dashboard; a React 19 and Tailwind 4 settings app; a React 19 issue tracker with a command palette, drag to reorder and a detail pane; and a music library and player with album art, a track list and a working scrubber.

## Test an app

Apps can run headlessly, driven by scripted input, and save a screenshot:

```console
$ NATIVE_STEPS='click #wave | print #greeting' NATIVE_SNAPSHOT=out.png ./hello
Hello, native
```

See the [CLI reference](packages/cli/docs/cli.md) for every step.

## Documentation

- [Supported features](packages/cli/docs/supported.md): the HTML, CSS and DOM that compile today.
- [How it works](packages/cli/docs/how-it-works.md): what happens at build time and what's left for runtime.
- [CLI reference](packages/cli/docs/cli.md): commands, headless runs and window size.
- [Windows, menus and the app's life](packages/cli/docs/app.md): opening windows from links and script, messages between them, the menu bar and context menus.
- [Web platform tests](packages/cli/docs/wpt.md): conformance against the suite browsers share.
- [Known compiler limitations](packages/cli/docs/compiler-limitations.md): compiler gaps and their workarounds.
- [Examples](examples): apps in this repository.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, the test and conformance gates, and how to work on a change.

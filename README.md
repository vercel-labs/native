# Native SDK

<p>
  <a href="https://vercel.com/labs#active-experiments"><img alt="Vercel Labs Experiment" src="https://img.shields.io/badge/LABS-EXPERIMENT-0a0a0a.svg?style=for-the-badge&amp;logo=Vercel&amp;labelColor=000000" height="28"></a>
  <a href="https://www.npmjs.com/package/@native-sdk/cli"><img alt="npm version: @native-sdk/cli" src="https://img.shields.io/npm/v/%40native-sdk%2Fcli.svg?style=for-the-badge&amp;labelColor=000000" height="28"></a>
  <a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue.svg?style=for-the-badge&amp;labelColor=000000" height="28"></a>
  <a href="https://www.npmjs.com/package/@native-sdk/cli"><img alt="npm downloads per month: @native-sdk/cli" src="https://img.shields.io/npm/dm/%40native-sdk%2Fcli.svg?style=for-the-badge&amp;labelColor=000000&amp;label=npm%20downloads" height="28"></a>
</p>

HTML, CSS and TypeScript compiled into native apps, without Node.js. Native SDK's compiler, the `native` CLI, compiles the HTML and CSS ahead of time, and [scriptc](https://scriptc.dev) compiles the TypeScript, both your app's and the SDK's runtime, to machine code. The result is a small native app bundle — an executable with the images, fonts and other files it reads — that runs without a browser, webview or JavaScript engine.

Native SDK is experimental and supports a subset of HTML, CSS and the DOM. Run `native check` on an app to see what it uses that isn't supported, and see [supported features](packages/cli/docs/supported.md) for details. It builds on macOS, Linux and Windows: the windowed host on macOS, the Win32 host on Windows, and the same pages run headlessly on Linux for the web-platform tests.

## Installation

Install the CLI into your app's project with Node.js 24 or later:

```console
$ npm install -D @native-sdk/cli
```

Run it through your package.json scripts:

```json
{
  "scripts": {
    "dev": "native dev",
    "build": "native build"
  }
}
```

`npm run dev` watches the app and applies edits as you save, and `npm run build` builds it. Both work on the project directory. For a one-off command, run the package by its name: `npx @native-sdk/cli check`.

Building an app also needs a C compiler for its host. On macOS the Xcode command line tools provide it (`xcode-select --install`); on Linux, [shipping a Linux app](packages/cli/docs/linux.md) lists the host libraries and the packaging tools; and on Windows `zig` on the PATH builds both scriptc's link and the Win32 host.

An app is a directory of its own and doesn't have to live in this repository. To work on Native SDK itself, or to run the CLI from a clone, see [CONTRIBUTING.md](CONTRIBUTING.md).

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

`npm run build` (`native build`) writes a self-contained app bundle named after the project directory: in a directory called `hello`, on macOS `hello.app`, with its images, fonts and other files in `Contents/Resources`, and elsewhere the executable `hello` with a `hello.resources` directory beside it. `-o <path>` names another output. The output path is still a way to run the app:

```console
$ npm run build
$ ./hello
```

`npx @native-sdk/cli run` builds and runs in one step. `npm run dev` (`native dev`) watches the app and applies HTML and CSS edits to the open window in place; a TypeScript edit rebuilds and relaunches it, keeping what state it can. The [examples](examples) are a counter; a todo list; an article with inline formatting and a link; a dashboard with a sidebar, stat cards and a members table; an animated canvas piece; a canvas particle field; a spinning WebGL 2 cube; a WebGL 2 texture uploaded from a file; a `@keyframes` and transition piece; a todo list in Preact; an input method composing marked text in a field; a playable three.js game; a lit three.js hero scene; a React 19 and Tailwind 4 dashboard; and a React 19 and Tailwind 4 settings app.

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

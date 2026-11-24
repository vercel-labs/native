# @native-sdk/cli

`native` builds native apps from HTML, CSS and TypeScript. It compiles the HTML and CSS ahead of time,
and [scriptc](https://scriptc.dev) compiles the TypeScript, both your app's and the SDK's runtime, to
machine code. The result is an app bundle that runs without a browser, webview or JavaScript engine.

Native SDK is experimental and supports a subset of HTML, CSS and the DOM.

```console
$ npm install -D @native-sdk/cli
```

Run it through your package.json scripts, with `npm run dev` and `npm run build`:

```json
{
  "scripts": {
    "dev": "native dev",
    "build": "native build"
  }
}
```

Both work on the project directory. For a one-off command, run the package by its name:

```console
$ npx @native-sdk/cli check
$ npx @native-sdk/cli run
```

Node.js 24 or later is required. On macOS the Xcode command line tools provide the compiler, on
Linux the host libraries listed in the [CLI reference](https://github.com/vercel-labs/native/blob/next/packages/cli/docs/cli.md)
are needed, and on Windows `zig` on the PATH builds the Win32 host.

See the [repository](https://github.com/vercel-labs/native) for documentation and examples.

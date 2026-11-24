# @native-sdk/cli

`native` builds native apps from HTML, CSS and TypeScript. It compiles the HTML and CSS ahead of time,
and [scriptc](https://scriptc.dev) compiles the TypeScript, both your app's and the SDK's runtime, to
machine code. The result is an app bundle that runs without a browser, webview or JavaScript engine.

Native SDK is experimental and supports a subset of HTML, CSS and the DOM.

```console
$ npm install --save-dev @native-sdk/cli
$ npx @native-sdk/cli build . -o hello
$ ./build/hello
```

The package installs the `native` command, so a `package.json` script runs it without `npx`:

```json
{
  "scripts": {
    "build": "native build . -o build/hello",
    "dev": "native dev .",
    "check": "native check ."
  }
}
```

Don't write `npx native`: the package named `native` on npm is unrelated.

Node.js 24 or later is required. On macOS the Xcode command line tools provide the compiler, on
Linux the host libraries listed in the [CLI reference](https://github.com/vercel-labs/native/blob/next/packages/cli/docs/cli.md)
are needed, and on Windows `zig` on the PATH builds the Win32 host.

See the [repository](https://github.com/vercel-labs/native) for documentation and examples.

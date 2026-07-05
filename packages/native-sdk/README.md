# @native-sdk/cli

CLI tools for the [Native SDK](https://zero-native.dev), a Zig native app framework with secure WebView surfaces, native controls, and OS capabilities.

## Install

```bash
npm install -g @native-sdk/cli
```

## Usage

```bash
native init my_app
cd my_app
native dev
```

The default scaffold is a native-rendered markup app with no build files — `native dev|build|test` own the build. Web-frontend scaffolds (`--frontend vite` etc.) install their generated frontend dependencies automatically on first run.

Use WebViews for rich product UI, and add native windows, menus, shortcuts, views, dialogs, clipboard, credentials, and OS services where the platform should own the interaction.

## Commands

| Command | Description |
|---------|-------------|
| `native init [name] [--frontend <native\|next\|vite\|react\|svelte\|vue>] [--full]` | Scaffold a new Native SDK project |
| `native dev [dir]` | Build and run the app (markup hot reload; managed frontend dev server when configured) |
| `native build [dir]` | Build a ReleaseFast binary into `zig-out/bin/` |
| `native test [dir]` | Run the app's test suite |
| `native check [dir]` | Validate `src/**.zml` markup and `app.zon` |
| `native eject [dir]` | Write an owned build.zig/build.zig.zon into the app |
| `native doctor` | Check host environment, WebView, manifest, and CEF |
| `native validate` | Validate `app.zon` against the manifest schema |
| `native package` | Package the app for distribution |
| `native bundle-assets` | Copy frontend assets into the build output |
| `native automate` | Interact with a running app's automation server |
| `native skills list` | List built-in AI agent skills |
| `native skills get <name>` | Output AI agent skill content |
| `native version` | Print the native version |

## More

See the [full documentation](https://zero-native.dev) for details on the app model, native controls, capabilities, bridge, security, and packaging.

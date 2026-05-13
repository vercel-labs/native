# zero-native

CLI tools for [zero-native](https://zero-native.dev), a Zig desktop app shell built around the system WebView.

## Install

```bash
npm install -g zero-native
```

## Usage

```bash
zero-native init my_app --frontend vite
cd my_app
zig build run
```

The first run installs the generated frontend dependencies automatically.

## Commands

| Command | Description |
|---------|-------------|
| `zero-native init [name] --frontend <next\|vite\|react\|svelte\|vue\|angular>` | Scaffold a new zero-native project |
| `zero-native dev --binary <path>` | Start the app with a managed frontend dev server |
| `zero-native doctor` | Check host environment, WebView, manifest, and CEF |
| `zero-native validate` | Validate `app.zon` against the manifest schema |
| `zero-native package` | Package the app for distribution |
| `zero-native bundle-assets` | Copy frontend assets into the build output |
| `zero-native automate` | Interact with a running app's automation server |
| `zero-native skills list` | List built-in AI agent skills |
| `zero-native skills get <name>` | Output AI agent skill content |
| `zero-native version` | Print the zero-native version |

## More

See the [full documentation](https://zero-native.dev) for details on the app model, bridge, security, and packaging.

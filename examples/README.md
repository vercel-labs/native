# Native SDK Examples

Most examples here are zero-config apps: `app.zon` + `src/` (+ `assets/`) and nothing else. The `native` CLI owns their build — run any of them straight from its directory:

```sh
native dev     # build and run with hot reload
native test    # run the app's test suite
native build   # produce a ReleaseFast binary in zig-out/bin/
```

(In this repository the CLI is `zig-out/bin/native`, built by `zig build` at the root.) A handful of examples own a `build.zig` because they genuinely outgrow the generated graph — each one's build file opens with the reason.

## Zero-config apps (native-rendered)

| Example | Shows |
| --- | --- |
| `habits` | The smallest markup app: one `.zml` view, a plain-form Model/Msg/update. |
| `calculator` | A complete small app: markup keypad, text-field keyboard path, chrome shortcuts, theming. |
| `notes` | Persistence through the effects channel: debounced writes, restore on boot, dialogs, search. |
| `kanban` | Builder-view boards with drag interactions. |
| `feed` | Windowed 100k-row list virtualization with runtime-owned scrolling. |
| `soundboard` | Album grid with decoded cover art, context menus, timers, and a custom theme. |
| `deck` | Two model-declared windows and a dense track ledger. |
| `markdown-viewer` | Real file I/O through effects, hidden-inset titlebar retrofit, preview + editor. |
| `system-monitor` | Live process sampling, confirmation dialogs, a settings window. |
| `gpu-surface` | A Metal-backed GPU surface composed beside native controls and WebView content. |
| `gpu-dashboard` | Native chrome, a GPU surface, and a retained canvas display list. |
| `gpu-components` | The retained GPU widget controls in one native-first component lab. |
| `canvas-preview` | Canvas + WebView in one window, panes snapped to canvas anchors, a status item. |
| `effects-probe` | The effect system live: spawn/fetch/file effects, cancellation, worker wakes. |

## Examples that own their build

| Example | Why it keeps a build.zig |
| --- | --- |
| `hello` | Smallest WebView shell, with the SDK module wiring spelled out by hand. |
| `webview` | Bridge commands, window APIs, security policy, automation, and optional CEF engine flags. |
| `command-app` | One command routed from toolbar, menu, tray, shortcut, and bridge entry points. |
| `capabilities` | Guarded OS services: notifications, clipboard, credentials, dialogs, file drops. |
| `native-shell` | Native toolbar/sidebar/statusbar chrome around a WebView content area. |
| `native-panels` | Split native panels and stacked native controls around WebView content. |
| `browser` | Layered WebViews for isolated page content, engine link flags wired by hand. |
| `next`, `react`, `svelte`, `vue` | Frontend projects with managed install/build/dev-server steps. |
| `ui-inbox` | The builder-view inbox; its `-Dmobile` lib step feeds the mobile host shims. |
| `mobile-canvas` | Builds the mobile embed static library consumed by the iOS/Android canvas shims. |

`mobile-shell`, `ios`, and `android` are mobile host projects (Xcode/Gradle shells plus shared `app.zon` metadata) rather than desktop app directories.

Start with `habits` for the native-rendered markup path, or `hello` for the WebView path. Move to `webview` when you need native commands or WebView policy, `capabilities` for guarded OS services, the GPU trio when you want custom-rendered or retained-canvas panes, and a frontend example when building a real web frontend.

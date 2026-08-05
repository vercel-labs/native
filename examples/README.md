# Native SDK Examples

Most examples here are zero-config apps: `app.zon` + `src/` (+ `assets/`) and nothing else. The `native` CLI owns their build — run any of them straight from its directory:

```sh
native dev     # build and run with hot reload
native test    # run the app's test suite
native build   # produce a ReleaseFast binary in zig-out/bin/
```

(In this repository the CLI is `zig-out/bin/native`, built by `zig build` at the root.) A handful of examples own a `build.zig` because they genuinely outgrow the generated graph — each one's build file opens with the reason.

## Start here: TypeScript + Native markup

TypeScript is the primary app-authoring language. A new `native init my_app` project has `src/core.ts`, `src/app.native`, and `app.zon`; the core compiles ahead of time to native code, so no JS runtime ships in the app. These examples are the clearest substantial references for that path:

| Example | Shows |
| --- | --- |
| `audio-capture` | macOS 15+ system/microphone permissions, device enumeration, aligned PCM draining, and live peaks. |
| `ai-chat-ts` | Multi-module TypeScript core, text editing, `Cmd.fetch`, environment messages, and deterministic replay. |
| `soundboard-ts` | Full music player: audio effects, timers, search, assets, native context menus, and adaptive markup. |
| `system-monitor-ts` | Subprocess effects, timers, parsing, tables, charts, controlled scroll, and confirmation flows. |

The `-ts` suffix is historical: `soundboard-ts` and `system-monitor-ts` distinguish ports from older Zig originals in the same catalog, while `ai-chat-ts` predates the unsuffixed convention. It is not a template convention: new TypeScript apps such as `audio-capture` need no suffix because TypeScript is the default. Many unsuffixed showcase apps predate that default and still use `src/main.zig`; use them for their feature or visual patterns, not as evidence that new app logic should be Zig.

## Earlier native-rendered showcase apps (Zig cores)

| Example | Shows |
| --- | --- |
| `habits` | The smallest markup app: one `.native` view, a plain-form Model/Msg/update. |
| `calculator` | A complete small app: markup keypad, text-field keyboard path, chrome shortcuts, theming. |
| `notes` | Persistence through the effects channel: debounced writes, restore on boot, dialogs, search. |
| `kanban` | Builder-view boards with drag interactions. |
| `feed` | Windowed 100k-row list virtualization with runtime-owned scrolling. |
| `soundboard` | Album grid with decoded cover art, context menus, timers, and a custom theme. |
| `deck` | Two model-declared windows and a dense track ledger. |
| `markdown-viewer` | Real file I/O through effects, hidden-inset titlebar retrofit, preview + editor. |
| `code-editor` | Platform folder picker, bounded filesystem tree, and syntax-highlighted source editor. |
| `system-monitor` | Live process sampling, confirmation dialogs, a settings window. |
| `gpu-surface` | A Metal-backed GPU surface composed beside native controls and WebView content. |
| `gpu-dashboard` | Native chrome, a GPU surface, and a retained canvas display list. |
| `gpu-components` | The retained GPU widget controls in one native-first component lab. |
| `canvas-preview` | Canvas + WebView in one window, panes snapped to canvas anchors, a status item. |
| `effects-probe` | The effect system live: spawn/fetch/file effects, cancellation, worker wakes. |
| `menu-bar` | The menu-bar app lifecycle: `close_policy = "hide"`, a status item whose Open/Quit rows drive `fx.showWindow`/`fx.quitApp`, Dock reopen. |

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

Start with `native init` for a small TypeScript + Native markup app, then use `audio-capture`, `ai-chat-ts`, `soundboard-ts`, or `system-monitor-ts` according to the feature you need. Use `habits` when you specifically want the smallest Zig-core equivalent, `hello` for the lower-level WebView path, `webview` for native commands or WebView policy, `capabilities` for guarded OS services, and the GPU trio for custom-rendered or retained-canvas panes.

---
name: native-sdk
description: Discovery skill for the Native SDK, the complete toolkit for building native desktop applications. Apps are authored in TypeScript + declarative Native markup (.native) by default and compiled to native code with no JS runtime in the binary; Zig cores are an explicit alternative, and WebViews are the optional web-content path. Use when the user asks what the Native SDK is, how to build a Native SDK app, author native UI, scaffold an app, configure app.zon, add bridge commands, embed web content, package an app, test a running app, or automate a Native SDK app.
allowed-tools: Bash(native:*), Bash(npx @native-sdk/cli:*)
hidden: true
---

# Native SDK

The Native SDK is the complete toolkit for building native desktop applications. **The primary authoring path is TypeScript app logic in `src/core.ts` plus declarative Native markup in `.native` files.** The TypeScript core is checked and compiled ahead of time to native code, so the shipped binary contains no browser, WebView, JS runtime, or interpreter. Zig is how the toolkit itself works and is a first-class, explicitly chosen app-core alternative (`--template zig-core`); it is not the default inferred from the SDK's implementation. Every app embeds a deterministic automation server, so agents can snapshot, drive, and screenshot the running window. Desktop is the mature surface (macOS deepest, Linux and Windows exercised in CI); mobile embedding is experimental. WebView surfaces coexist as the optional path for embedding web content or hosting an existing web frontend.

## Start here

This file is a discovery stub for agents that installed the Native SDK once with a skills installer such as `npx skills add native-sdk`. Before implementing or explaining Native SDK app work, use the installed CLI to discover and load the current skill content:

```bash
native skills list
native skills get core
native skills get native-ui
native skills get ts-core
```

Use `native skills get core` for initial orientation. For the default app-authoring path, load **both** `native-ui` (views, bindings, the app loop) and `ts-core` (the TypeScript subset, effects, subscriptions, and modules) before implementing. Load `ts-services` too when the tree has `src/services/` or ordinary TypeScript needs filesystem/process/JSON/regex/Map/Date/class work behind `Cmd.request`. Use `native skills get core --full` when work reaches lower-level runtime wiring, WebViews, bridge/security, native capabilities, packaging, or debugging. Use `native skills get automation` when testing a running app, taking snapshots, requesting reloads, or using the built-in automation server. Use `native skills get zig` only for an existing Zig core, a toolkit extension, SDK implementation work, or a Zig 0.16 compile error.

## Quick orientation

```bash
npm install -g @native-sdk/cli
native init my_app
cd my_app
native dev
```

`native init my_app` generates the primary three-file app: `app.zon`, `src/app.native` (the markup view), and `src/core.ts` (`Model`, `Msg`, `update`). Inspect the tree before editing an existing app and preserve the core language it already uses. `src/main.zig` means the app explicitly uses the Zig-core template; web-frontend shells additionally carry `frontend/` and usually owned build/runtime wiring.

---
name: zero-native
description: Discovery skill for zero-native, a cross-platform native app framework inspired by the web - native-rendered apps from .zml markup views plus Zig logic by default, with WebView-shell apps as a coexisting architecture. Use when the user asks what zero-native is, how to build a zero-native app, author native UI, scaffold an app, configure app.zon, choose a WebView engine, add bridge commands, package an app, test a running app, or automate a zero-native app.
allowed-tools: Bash(zero-native:*), Bash(npx zero-native:*)
hidden: true
---

# zero-native

zero-native is a Zig desktop app shell for building native desktop apps with web UIs. It uses the platform WebView for small native-footprint apps and can bundle Chromium through CEF where supported.

## Start here

This file is a discovery stub for agents that installed zero-native once with a skills installer such as `npx skills add zero-native`. Before implementing or explaining zero-native app work, use the installed CLI to discover and load the current skill content:

```bash
zero-native skills list
zero-native skills get core
zero-native skills get core --full
```

Use `zero-native skills get core` for initial orientation. Use `zero-native skills get core --full` for implementation tasks because it includes the reference files for project anatomy, runtime, frontend assets, bridge/security/native capabilities, packaging, and debugging. Use `zero-native skills get automation` when testing a running app, taking snapshots, requesting reloads, or using the built-in automation server.

## Quick orientation

```bash
npm install -g zero-native
zero-native init my_app --frontend next
cd my_app
zig build run
```

Generated apps center on `app.zon`, `src/main.zig`, `src/runner.zig`, `build.zig`, and `frontend/`. Inspect those files before editing an existing app.

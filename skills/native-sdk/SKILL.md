---
name: native-sdk
description: Discovery skill for the Native SDK, the complete toolkit for building native desktop applications - views are declarative Native markup (.native), logic is plain Zig, and the toolkit's own engine renders every pixel, with WebView surfaces as the optional web-content path. Use when the user asks what the Native SDK is, how to build a Native SDK app, author native UI, scaffold an app, configure app.zon, add bridge commands, embed web content, package an app, test a running app, or automate a Native SDK app.
allowed-tools: Bash(native:*), Bash(npx @native-sdk/cli:*)
hidden: true
---

# Native SDK

The Native SDK is the complete toolkit for building native desktop applications. Views are declarative markup in `.native` files, logic is plain Zig, and the toolkit's own engine draws every pixel into real OS windows — no browser, no WebView, no interpreter in the binary. Every app embeds a deterministic automation server, so agents can snapshot, drive, and screenshot the running window. Desktop is the mature surface (macOS deepest, Linux and Windows exercised in CI); mobile embedding is experimental. WebView surfaces coexist as the optional path for embedding web content or hosting an existing web frontend.

## Start here

This file is a discovery stub for agents that installed the Native SDK once with a skills installer such as `npx skills add native-sdk`. Before implementing or explaining Native SDK app work, use the installed CLI to discover and load the current skill content:

```bash
native skills list
native skills get core
native skills get core --full
```

Use `native skills get core` for initial orientation. Use `native skills get core --full` for implementation tasks because it includes the reference files for project anatomy, runtime, frontend assets, bridge/security/native capabilities, packaging, and debugging. Use `native skills get automation` when testing a running app, taking snapshots, requesting reloads, or using the built-in automation server. Use `native skills get zig` when `zig build` fails with "no member named" errors on std APIs — the SDK requires Zig 0.16.0, and that skill maps each pre-0.16 idiom's compile error to the current one.

## Quick orientation

```bash
npm install -g @native-sdk/cli
native init my_app
cd my_app
native dev
```

Generated apps center on `app.zon`, `src/app.native` (the markup view), and `src/main.zig` (Model, Msg, update). Inspect those files before editing an existing app; web-frontend shells additionally carry `frontend/` and a `build.zig`.

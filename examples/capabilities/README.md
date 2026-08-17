# Native SDK capabilities example

This example shows guarded OS capabilities from trusted WebView code:

- Platform support discovery.
- Open URL, reveal path, and recent document OS services.
- Notifications.
- Clipboard text read and write.
- Message dialogs.
- Credential set, get, and delete.
- File-drop events delivered to Zig and the WebView event bridge, plus a real canvas `drop_files` target.
- File association and custom URL scheme packaging metadata.
- App activation and deactivation events.

Run with the system backend:

```sh
zig build run -Dplatform=macos -Dweb-engine=system
```

Run the headless test path:

```sh
zig build test -Dplatform=null
```

For the macOS host integration check, run the app with the system backend and drag a Finder file onto the right-hand **Drop files here** canvas. The status bar must report `Widget target 2 fired` and the dropped path. Dropping over the left WebView must still report the ordinary app-level drop without a widget target. The guest-VM harness cannot synthesize an AppKit drag session yet, so this is the documented manual receipt for the real host path.

Run all native-first example tests from the repository root:

```sh
zig build test-examples-native
```

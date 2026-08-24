# Swift toolchain proof

This macOS-only Phase 1 fixture proves that app-owned Swift can cross the C
ABI into an ordinary Native SDK app without an Xcode project, helper process,
or bundled dynamic library.

`src/NativeView.swift` exports retained `NSHostingView` construction and
release functions with `@_cdecl`, exercises AVFoundation's Swift overlay, uses
the non-framework `RegexBuilder` module to prove its autolink library is
forwarded to Zig, and calls a macOS 26 SwiftUI API behind an availability guard
to prove newer split-framework symbols remain linkable at the macOS 12 floor.
`src/main.zig` calls only those C symbols; the pointer remains opaque to Zig
and ownership stays with the app.

Run the focused gates from this directory:

```sh
zig build test -Dplatform=macos
zig build -Doptimize=Debug -Dplatform=macos
./zig-out/bin/swift-toolchain-proof --swift-proof-smoke
zig build signed-package -Dplatform=macos
codesign --verify --deep --strict zig-out/package/swift-toolchain-proof.app
```

The fixture declares macOS 12.0 at the app boundary; the Swift object, final Zig
executable, and packaged app metadata must all carry that floor. Its direct load
commands must not absorb newer transitive framework splits such as
`SwiftUICore`; the SDK's back-deployment metadata keeps those symbols on the
`SwiftUI` umbrella.
It is exercised with Xcode 26 and Swift 6.2 in Phase 1; the build helper emits an
actionable error when Xcode, the macOS SDK, or `swiftc` is unavailable.

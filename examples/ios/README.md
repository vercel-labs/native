# iOS Example

A minimal iOS mobile shell that embeds a zero-native static library from Swift. The example keeps a native UIKit header above a WKWebView workspace.

UIKit owns the mobile shell layout: safe-area placement, Dynamic Type text, orientation relayout, and the `WKWebView` workspace. The zero-native runtime is driven through the C ABI from the host controller.

## Build the native library

Build or package an iOS static library from the repository root, then copy it into this example:

```bash
zig build lib -Dtarget=aarch64-ios
mkdir -p examples/ios/Libraries
cp zig-out/lib/libzero-native.a examples/ios/Libraries/libzero-native.a
```

The Xcode project expects the library at `Libraries/libzero-native.a` and the C header at `ZeroNativeIOSExample/zero_native.h`.

## Run

Open the project in Xcode:

```bash
open examples/ios/ZeroNativeIOSExample.xcodeproj
```

Select a simulator or device and run the `ZeroNativeIOSExample` scheme.

## Files

- `ZeroNativeIOSExample/ZeroNativeHostViewController.swift` hosts native UIKit chrome, a `WKWebView` workspace, and the zero-native C ABI.
- `ZeroNativeIOSExample/zero_native.h` declares the C ABI expected from `libzero-native.a`.
- `app.zon` records the mobile example metadata for zero-native tooling.

## Host lifecycle

- `viewDidLoad` creates and starts the zero-native app.
- `viewDidLayoutSubviews` forwards the current WebView size and screen scale with `zero_native_app_resize`, then requests a frame.
- Controller teardown stops and destroys the app.

The generic desktop `ShellView` runtime is not mapped to UIKit yet; native mobile chrome is implemented directly in Swift in this example.

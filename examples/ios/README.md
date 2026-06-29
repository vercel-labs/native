# iOS Example

A minimal iOS mobile shell that embeds a zero-native static library from Swift. The example keeps a native UIKit header above a WKWebView workspace and routes native header actions through the zero-native command path.

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
- `SceneDelegate` forwards activation and resignation with `zero_native_app_activate` and `zero_native_app_deactivate`.
- `viewDidLayoutSubviews` forwards the current WebView size, screen scale, safe-area insets, and keyboard inset with `zero_native_app_viewport`, then requests a frame.
- Keyboard frame changes adjust the `WKWebView` bottom constraint while also forwarding the keyboard inset to zero-native.
- The embedded C ABI exposes hardware key, committed text, and IME composition entry points for GPU/widget text fields.
- The embedded C ABI can expose retained GPU/widget accessibility semantics by indexed snapshot and dispatch widget accessibility actions for UIKit accessibility elements.
- The native Back and Refresh buttons call `zero_native_app_command` with stable mobile command IDs, update status from `zero_native_app_last_command_count`, and request a frame.
- Controller teardown stops and destroys the app.

The `app.zon` shell view tree describes this header and WebView workspace. Native mobile layout is still implemented in Swift so UIKit owns safe areas, keyboard avoidance, and scene lifecycle while zero-native receives the viewport metrics needed for GPU/widget layout.

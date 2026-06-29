# zero-native mobile-shell example

The mobile shell shape is implemented by the concrete platform hosts in `examples/ios` and `examples/android`.

- `examples/ios` uses a native UIKit header with a WKWebView workspace and native command buttons.
- `examples/android` uses a native Android header with a WebView workspace, JNI bridge, native command buttons, and system Back dispatch.

Both hosts leave keyboard avoidance in the native layout system while forwarding viewport metrics to zero-native: UIKit adjusts the WebView constraint from keyboard frame notifications, and Android uses `adjustResize` for soft-keyboard relayout.

Android orientation and screen-size changes stay in the same activity so the embedded runtime survives rotation while resize/frame events update the content surface.

The embedded ABI also includes hardware key, committed text, IME composition, retained GPU/widget accessibility semantics, and widget accessibility action entry points for future GPU/widget text fields.

Use those platform folders when building or running the example.

The shared mobile metadata in `app.zon` records the intended platforms, capabilities, command IDs, and shell view tree. Package generation maps that shell metadata to native host config for the header labels, command buttons, and WebView workspace while each mobile host still owns safe areas, keyboard behavior, and platform lifecycle.

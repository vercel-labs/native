# zero-native mobile-shell example

The mobile shell shape is implemented by the concrete platform hosts in `examples/ios` and `examples/android`.

- `examples/ios` uses a native UIKit header with a WKWebView workspace.
- `examples/android` uses a native Android header with a WebView workspace and JNI bridge.

Use those platform folders when building or running the example.

The shared mobile metadata in `app.zon` records the intended platforms and capabilities for tooling. The runtime view tree is still owned by each native mobile host, so generic desktop `ShellView` declarations are not materialized on iOS or Android yet.

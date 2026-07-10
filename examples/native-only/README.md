# Native-only host fixture

This canvas-only app sets `host = "native"`. Its desktop build must omit WebKit, WebKitGTK, WebView2, CEF, frontend output, and JavaScript bridge services while preserving the native window and GPU-surface runtime.

```sh
native validate app.zon
native test
native build -Dplatform=linux
```

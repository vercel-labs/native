// Windows Chromium currently shares the Win32 host surface with the system backend.
// CEF-specific browser creation is isolated behind this translation unit so the
// build can link the CEF runtime and evolve without changing the Zig ABI.
// When building CEF, we skip the WebView2-specific initialization code.
#define ZERO_NATIVE_CEF_BUILD
#include "webview2_host.cpp"

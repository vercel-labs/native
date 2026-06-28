# zero-native Examples

Use these examples as a progressive path through zero-native:

- `hello` is the smallest desktop shell with inline HTML.
- `webview` demonstrates bridge commands, built-in window APIs, security policy, automation, and optional CEF.
- `command-app` demonstrates one command handled from a native toolbar button, native menu item, tray item, app shortcut, and WebView bridge call.
- `capabilities` demonstrates guarded OS services, notifications, clipboard, credentials, dialogs, file-drop events, and app activation events.
- `native-shell` demonstrates native toolbar/sidebar/statusbar views with a WebView content area.
- `native-panels` demonstrates split native panels and stacked native controls around WebView content.
- `gpu-surface` demonstrates a Metal-backed GPU surface composed beside native controls and WebView content.
- `gpu-dashboard` demonstrates native chrome, a GPU surface, and a retained canvas dashboard display list.
- `browser` is a vanilla no-build shell that uses layered WebViews for isolated page content on macOS and Linux system WebViews.
- `react`, `svelte`, `vue`, and `next` show framework projects with managed frontend assets and dev-server workflows.
- `mobile-shell` summarizes the native-header plus WebView workspace pattern used by the mobile hosts.
- `ios` and `android` show mobile shells with native headers, WebView content, and the zero-native C ABI from `libzero-native.a`.

Start with `hello`, then move to `webview` when you need native commands or WebView policy. Use `command-app` when command routing needs to span native, tray, and web entry points, `capabilities` when you need guarded OS services, `native-shell` when you want native app chrome around web content, `native-panels` when you want split native panels with WebView workspace content, `gpu-surface` when you want a custom-rendered GPU pane, `gpu-dashboard` when you want the native canvas display-list path, `browser` when you want to see layered native WebViews, and a framework example when building a real frontend.

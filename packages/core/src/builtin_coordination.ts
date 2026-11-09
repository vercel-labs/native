/** Complete builtin command routing and error projection. Native owns raw JSON,
 * buffers, handler/capability execution and response-envelope serialization.
 */
type NscBuiltinFamily = { prefix: string; permission: number; denial: string; unknown: string };
type NscBuiltinVerb = { name: string; family: number; operation: number };
type NscBuiltinError = { name: string; code: number; message: string };
const NSC_BUILTIN_FAMILIES: nscContracts.Immutable<NscBuiltinFamily[]> = [
  {"prefix": "native-sdk.command.", "permission": 1, "denial": "Command API is not permitted", "unknown": "Unknown command command"},
  {"prefix": "native-sdk.window.", "permission": 2, "denial": "Window API is not permitted", "unknown": "Unknown window command"},
  {"prefix": "native-sdk.view.", "permission": 3, "denial": "View API is not permitted", "unknown": "Unknown view command"},
  {"prefix": "native-sdk.webview.", "permission": 2, "denial": "WebView API is not permitted", "unknown": "Unknown WebView command"},
  {"prefix": "native-sdk.platform.", "permission": 2, "denial": "Platform API is not permitted", "unknown": "Unknown platform command"},
  {"prefix": "native-sdk.dialog.", "permission": 0, "denial": "Dialog API is not permitted", "unknown": "Unknown dialog command"},
  {"prefix": "native-sdk.os.", "permission": 0, "denial": "OS API is not permitted", "unknown": "Unknown OS command"},
  {"prefix": "native-sdk.clipboard.", "permission": 0, "denial": "Clipboard API is not permitted", "unknown": "Unknown clipboard command"},
  {"prefix": "native-sdk.credentials.", "permission": 0, "denial": "Credentials API is not permitted", "unknown": "Unknown credentials command"},
];
const NSC_BUILTIN_VERBS: nscContracts.Immutable<NscBuiltinVerb[]> = [
  {"name": "native-sdk.command.invoke", "family": 1, "operation": 1},
  {"name": "native-sdk.command.list", "family": 1, "operation": 2},
  {"name": "native-sdk.platform.supports", "family": 5, "operation": 3},
  {"name": "native-sdk.window.list", "family": 2, "operation": 4},
  {"name": "native-sdk.window.create", "family": 2, "operation": 5},
  {"name": "native-sdk.window.focus", "family": 2, "operation": 6},
  {"name": "native-sdk.window.close", "family": 2, "operation": 7},
  {"name": "native-sdk.view.create", "family": 3, "operation": 8},
  {"name": "native-sdk.view.list", "family": 3, "operation": 9},
  {"name": "native-sdk.view.update", "family": 3, "operation": 10},
  {"name": "native-sdk.view.setFrame", "family": 3, "operation": 11},
  {"name": "native-sdk.view.setVisible", "family": 3, "operation": 12},
  {"name": "native-sdk.view.focus", "family": 3, "operation": 13},
  {"name": "native-sdk.view.focusNext", "family": 3, "operation": 14},
  {"name": "native-sdk.view.focusPrevious", "family": 3, "operation": 15},
  {"name": "native-sdk.view.close", "family": 3, "operation": 16},
  {"name": "native-sdk.webview.create", "family": 4, "operation": 17},
  {"name": "native-sdk.webview.list", "family": 4, "operation": 18},
  {"name": "native-sdk.webview.setFrame", "family": 4, "operation": 19},
  {"name": "native-sdk.webview.navigate", "family": 4, "operation": 20},
  {"name": "native-sdk.webview.setZoom", "family": 4, "operation": 21},
  {"name": "native-sdk.webview.setLayer", "family": 4, "operation": 22},
  {"name": "native-sdk.webview.close", "family": 4, "operation": 23},
  {"name": "native-sdk.dialog.openFile", "family": 6, "operation": 24},
  {"name": "native-sdk.dialog.saveFile", "family": 6, "operation": 25},
  {"name": "native-sdk.dialog.showMessage", "family": 6, "operation": 26},
  {"name": "native-sdk.os.showNotification", "family": 7, "operation": 27},
  {"name": "native-sdk.os.openUrl", "family": 7, "operation": 28},
  {"name": "native-sdk.os.revealPath", "family": 7, "operation": 29},
  {"name": "native-sdk.os.addRecentDocument", "family": 7, "operation": 30},
  {"name": "native-sdk.os.clearRecentDocuments", "family": 7, "operation": 31},
  {"name": "native-sdk.credentials.set", "family": 9, "operation": 32},
  {"name": "native-sdk.credentials.get", "family": 9, "operation": 33},
  {"name": "native-sdk.credentials.delete", "family": 9, "operation": 34},
  {"name": "native-sdk.clipboard.readText", "family": 8, "operation": 35},
  {"name": "native-sdk.clipboard.writeText", "family": 8, "operation": 36},
  {"name": "native-sdk.clipboard.read", "family": 8, "operation": 37},
  {"name": "native-sdk.clipboard.write", "family": 8, "operation": 38},
];
const NSC_BUILTIN_ERRORS: nscContracts.Immutable<NscBuiltinError[]> = [
  {"name": "UnsupportedService", "code": 0, "message": "Native service is not available on this platform"},
  {"name": "UnsupportedWindowTransparency", "code": 0, "message": "This backend cannot make window content transparent"},
  {"name": "WindowNotFound", "code": 0, "message": "Window was not found"},
  {"name": "WindowLimitReached", "code": 0, "message": "Window limit reached"},
  {"name": "DuplicateWindowLabel", "code": 0, "message": "Window id or label already exists"},
  {"name": "MissingWindowSource", "code": 0, "message": "Window source is missing"},
  {"name": "WindowSourceTooLarge", "code": 0, "message": "Window source is too large"},
  {"name": "CreateFailed", "code": 5, "message": "Native view creation failed"},
  {"name": "MissingWebViewUrl", "code": 0, "message": "WebView URL is missing"},
  {"name": "InvalidWebViewWindowId", "code": 0, "message": "windowId must be a non-negative integer"},
  {"name": "CrossWindowWebViewDenied", "code": 0, "message": "WebView windowId must match the calling window"},
  {"name": "InvalidWebViewOptions", "code": 0, "message": "WebView options are invalid"},
  {"name": "WebViewNotFound", "code": 0, "message": "WebView was not found"},
  {"name": "WebViewLayerNotBuilt", "code": 0, "message": "this app was built without the web layer because nothing in app.zon declared web use; add \"webview\" to .capabilities (or a .frontend block / a .shell webview view) and rebuild"},
  {"name": "WebViewLimitReached", "code": 0, "message": "WebView limit reached"},
  {"name": "DuplicateWebViewLabel", "code": 0, "message": "WebView label already exists"},
  {"name": "ReservedWebViewLabel", "code": 0, "message": "WebView label \"main\" is reserved for the startup WebView"},
  {"name": "WebViewLabelTooLarge", "code": 0, "message": "WebView label is too large"},
  {"name": "WebViewUrlTooLarge", "code": 0, "message": "WebView URL is too large"},
  {"name": "UnsupportedChildWebViews", "code": 0, "message": "This backend does not support child WebViews yet"},
  {"name": "UnsupportedWebViewBridge", "code": 0, "message": "This backend does not support bridge-enabled child WebViews yet"},
  {"name": "UnsupportedMainWebViewFrame", "code": 0, "message": "This backend does not support resizing the main WebView yet"},
  {"name": "UnsupportedMainWebViewZoom", "code": 0, "message": "This backend does not support zooming the main WebView yet"},
  {"name": "UnsupportedMainWebViewLayer", "code": 0, "message": "This backend does not support changing the main WebView layer"},
  {"name": "NavigationDenied", "code": 0, "message": "URL is not allowed by navigation policy"},
  {"name": "InvalidExternalUrl", "code": 0, "message": "External URL is invalid"},
  {"name": "ExternalUrlTooLarge", "code": 0, "message": "External URL is too large"},
  {"name": "InvalidRevealPath", "code": 0, "message": "Reveal path is invalid"},
  {"name": "RevealPathTooLarge", "code": 0, "message": "Reveal path is too large"},
  {"name": "InvalidRecentDocumentPath", "code": 0, "message": "Recent document path is invalid"},
  {"name": "RecentDocumentPathTooLarge", "code": 0, "message": "Recent document path is too large"},
  {"name": "InvalidDialogOptions", "code": 0, "message": "Dialog options are invalid"},
  {"name": "DialogFieldTooLarge", "code": 0, "message": "Dialog field is too large"},
  {"name": "InvalidNotificationOptions", "code": 0, "message": "Notification options are invalid"},
  {"name": "NotificationFieldTooLarge", "code": 0, "message": "Notification field is too large"},
  {"name": "InvalidClipboardOptions", "code": 0, "message": "Clipboard options are invalid"},
  {"name": "ClipboardFieldTooLarge", "code": 0, "message": "Clipboard field is too large"},
  {"name": "InvalidCredentialOptions", "code": 0, "message": "Credential options are invalid"},
  {"name": "CredentialFieldTooLarge", "code": 0, "message": "Credential field is too large"},
  {"name": "CredentialNotFound", "code": 5, "message": "Credential was not found"},
  {"name": "InvalidTrayOptions", "code": 0, "message": "Tray options are invalid"},
  {"name": "TrayFieldTooLarge", "code": 0, "message": "Tray field is too large"},
  {"name": "InvalidPlatformFeature", "code": 0, "message": "Platform feature is invalid"},
  {"name": "InvalidWindowOptions", "code": 0, "message": "Window options are invalid"},
  {"name": "InvalidCommand", "code": 0, "message": "Command name is invalid"},
  {"name": "DuplicateWindowId", "code": 0, "message": "Window id already exists"},
  {"name": "InvalidViewOptions", "code": 0, "message": "View options are invalid"},
  {"name": "InvalidViewWindowId", "code": 0, "message": "view windowId must be a non-negative integer"},
  {"name": "CrossWindowViewDenied", "code": 0, "message": "view windowId must match the calling window"},
  {"name": "ViewNotFound", "code": 0, "message": "View was not found"},
  {"name": "ViewLimitReached", "code": 0, "message": "View limit reached"},
  {"name": "DuplicateViewLabel", "code": 0, "message": "View label already exists"},
  {"name": "ViewLabelTooLarge", "code": 0, "message": "View label is too large"},
  {"name": "ViewRoleTooLarge", "code": 0, "message": "View role is too large"},
  {"name": "ViewAccessibilityLabelTooLarge", "code": 0, "message": "View accessibility label is too large"},
  {"name": "ViewTextTooLarge", "code": 0, "message": "View text is too large"},
  {"name": "WidgetNodeLimitReached", "code": 5, "message": "Canvas widget node limit reached"},
  {"name": "WidgetTextTooLarge", "code": 5, "message": "Canvas widget text is too large"},
  {"name": "WidgetSemanticsListFull", "code": 5, "message": "Canvas widget semantics limit reached"},
  {"name": "DuplicateWidgetId", "code": 5, "message": "Canvas widget id already exists"},
  {"name": "UnsupportedViewKind", "code": 0, "message": "This backend does not support this native view kind yet"},
  {"name": "UnsupportedViewFocus", "code": 0, "message": "This backend does not support focusing this native view yet"},
  {"name": "NoSpaceLeft", "code": 5, "message": "Native response buffer is too small"},
  {"name": "BuiltinWindowListFailed", "code": 5, "message": "Failed to list windows"},
 ];
function nscBuiltinText(bytes: Uint8Array, text: string, prefix: boolean): boolean {
  if (prefix ? bytes.length < text.length : bytes.length !== text.length) return false;
  for (let i = 0; i < text.length; i++) if (bytes[i] !== text.charCodeAt(i)) return false;
  return true;
}
function nscBuiltinAppend(out: Uint8Array, at: number, text: string): number {
  for (let i = 0; i < text.length; i++) out[at + i] = text.charCodeAt(i);
  return at + text.length;
}
function nscvBuiltinCoordination(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[0] !== 89 || request[1] !== 1 || request[2]! > 2)
    throw new Error("invalid builtin coordination header");
  const mode = request[2]!;
  if (request[5] !== 0 || request[6] !== 0 || request[7] !== 0) throw new Error("invalid builtin coordination reserve");
  if (mode === 2) {
    if (request.length !== 8 || request[3]! > 1 || request[4]! > 1) throw new Error("invalid notification permission plan");
    const denied = request[3] === 1 && request[4] !== 1;
    const text = denied ? "Notification actions require command invoke permission" : "";
    const result = new Uint8Array(16 + text.length), data = new DataView(result.buffer);
    data.setUint32(0, 1, true); data.setUint32(4, mode, true); result[8] = denied ? 1 : 0;
    data.setUint32(12, text.length, true); nscBuiltinAppend(result, 16, text); return result;
  }
  if (request.length < 16 || request[4] !== 0 || request[3]! > (mode === 0 ? 9 : 0))
    throw new Error("invalid builtin coordination context");
  const input = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const count = input.getUint32(8, true), upper = input.getUint32(12, true);
  if (upper !== 0 || count !== request.length - 16) throw new Error("invalid builtin coordination extent");
  const value = request.subarray(16);
  if (mode === 1) {
    let code = 5, message = "Native command failed";
    for (const error of NSC_BUILTIN_ERRORS) if (nscBuiltinText(value, error.name, false)) {
      code = error.code; message = error.message; break;
    }
    const result = new Uint8Array(16 + message.length), data = new DataView(result.buffer);
    data.setUint32(0, 1, true); data.setUint32(4, mode, true); result[8] = code;
    data.setUint32(12, message.length, true); nscBuiltinAppend(result, 16, message); return result;
  }
  let family = 0, operation = 0;
  for (let i = 0; i < NSC_BUILTIN_FAMILIES.length; i++) if (nscBuiltinText(value, NSC_BUILTIN_FAMILIES[i]!.prefix, true)) { family = i + 1; break; }
  for (const verb of NSC_BUILTIN_VERBS) if (nscBuiltinText(value, verb.name, false)) { operation = verb.operation; break; }
  const context = request[3] === 0 ? family : request[3]!;
  const denial = context === 0 ? "" : NSC_BUILTIN_FAMILIES[context - 1]!.denial;
  const unknown = context === 0 ? "" : NSC_BUILTIN_FAMILIES[context - 1]!.unknown;
  const result = new Uint8Array(16 + denial.length + unknown.length), data = new DataView(result.buffer);
  data.setUint32(0, 1, true); data.setUint32(4, mode, true); result[8] = family; result[9] = operation;
  result[10] = family === 0 ? 0 : NSC_BUILTIN_FAMILIES[family - 1]!.permission;
  data.setUint16(12, denial.length, true); data.setUint16(14, unknown.length, true);
  nscBuiltinAppend(result, nscBuiltinAppend(result, 16, denial), unknown); return result;
}

export type ZeroNativeJson =
  | null
  | boolean
  | number
  | string
  | ZeroNativeJson[]
  | { [key: string]: ZeroNativeJson };

export type ZeroNativeErrorCode =
  | "invalid_request"
  | "unknown_command"
  | "permission_denied"
  | "handler_failed"
  | "payload_too_large"
  | "internal_error"
  | string;

export interface ZeroNativeInvokeError extends Error {
  code: ZeroNativeErrorCode;
}

export interface ZeroNativeWindowInfo {
  id: number;
  label: string;
  title: string;
  open: boolean;
  focused: boolean;
  x: number;
  y: number;
  width: number;
  height: number;
  scale: number;
}

export interface ZeroNativeCreateWindowOptions {
  label?: string;
  title?: string;
  width?: number;
  height?: number;
  x?: number;
  y?: number;
  restoreState?: boolean;
  url?: string;
}

export interface ZeroNativeRect {
  x?: number;
  y?: number;
  width: number;
  height: number;
}

export interface ZeroNativeWebViewInfo {
  label: string;
  windowId: number;
  url: string;
  x: number;
  y: number;
  width: number;
  height: number;
  layer: number;
  zoom: number;
  transparent: boolean;
  bridge: boolean;
  focused: boolean;
  open: boolean;
}

export interface ZeroNativeCreateWebViewOptions {
  /** Stable label for this child WebView. Defaults to "webview". Unique per native window. "main" is reserved for the startup WebView. */
  label?: string;
  /** Parent native window id. Defaults to the caller and must match the window that calls the command when provided. */
  windowId?: number;
  /** Target URL. Its origin must be listed in the runtime navigation policy. */
  url: string;
  /** Logical content coordinates relative to the parent window. */
  frame: ZeroNativeRect;
  /** Native z-order within the parent window. Higher layers appear above lower layers. */
  layer?: number;
  /** Best-effort transparent WebView background support for chrome/menu surfaces. */
  transparent?: boolean;
  /** Inject `window.zero` into this WebView when it is trusted app chrome. Defaults to false. */
  bridge?: boolean;
}

export interface ZeroNativeSetWebViewFrameOptions {
  /** Defaults to "webview". Use "main" to resize the startup WebView. */
  label?: string;
  /** Defaults to the caller and must match the window that calls the command when provided. */
  windowId?: number;
  frame: ZeroNativeRect;
}

export interface ZeroNativeNavigateWebViewOptions {
  /** Defaults to "webview". Child WebViews only. */
  label?: string;
  /** Defaults to the caller and must match the window that calls the command when provided. */
  windowId?: number;
  url: string;
}

export interface ZeroNativeSetWebViewZoomOptions {
  /** Defaults to "webview". Use "main" to zoom the startup WebView. */
  label?: string;
  /** Defaults to the caller and must match the window that calls the command when provided. */
  windowId?: number;
  /** Page zoom factor. Valid range: 0.25 to 5.0. */
  zoom: number;
}

export interface ZeroNativeSetWebViewLayerOptions {
  /** Defaults to "webview". "main" support depends on the native backend. */
  label?: string;
  /** Defaults to the caller and must match the window that calls the command when provided. */
  windowId?: number;
  layer: number;
}

export interface ZeroNativeCloseWebViewOptions {
  /** Defaults to "webview". The reserved "main" WebView cannot be closed. */
  label?: string;
  /** Defaults to the caller and must match the window that calls the command when provided. */
  windowId?: number;
}

export interface ZeroNativeWebViewHandle extends ZeroNativeWebViewInfo {
  setFrame(frame: ZeroNativeRect): Promise<ZeroNativeWebViewInfo>;
  navigate(url: string): Promise<ZeroNativeWebViewInfo>;
  setZoom(zoom: number): Promise<ZeroNativeWebViewInfo>;
  setLayer(layer: number): Promise<ZeroNativeWebViewInfo>;
  close(): Promise<ZeroNativeWebViewInfo>;
}

export type ZeroNativeViewKind =
  | "webview"
  | "toolbar"
  | "titlebar_accessory"
  | "titlebarAccessory"
  | "sidebar"
  | "statusbar"
  | "split"
  | "stack"
  | "button"
  | "icon_button"
  | "iconButton"
  | "list_item"
  | "listItem"
  | "checkbox"
  | "toggle"
  | "segmented_control"
  | "segmentedControl"
  | "text_field"
  | "textField"
  | "search_field"
  | "searchField"
  | "label"
  | "spacer"
  | "gpu_surface"
  | "gpuSurface"
  | "progress_indicator"
  | "progressIndicator";

export interface ZeroNativeViewInfo {
  /** Stable runtime view id for this window/view lifetime. */
  id: number;
  label: string;
  windowId: number;
  kind: ZeroNativeViewKind;
  parent: string | null;
  role: string;
  accessibilityLabel: string;
  text: string;
  url: string;
  x: number;
  y: number;
  width: number;
  height: number;
  layer: number;
  visible: boolean;
  enabled: boolean;
  transparent: boolean;
  bridge: boolean;
  gpuWidth: number;
  gpuHeight: number;
  gpuScale: number;
  gpuFrame: number;
  gpuTimestampNs: number;
  gpuInputTimestampNs: number;
  gpuInputLatencyNs: number;
  gpuInputLatencyBudgetNs: number;
  gpuInputLatencyBudgetExceededCount: number;
  gpuInputLatencyBudgetOk: boolean;
  gpuNonblank: boolean;
  gpuSampleColor: number;
  canvasRevision: number;
  canvasCommandCount: number;
  canvasFrameRequiresRender: boolean;
  canvasFrameFullRepaint: boolean;
  canvasFrameBatchCount: number;
  canvasFrameEncoderCommandCount: number;
  canvasFrameEncoderCacheActionCount: number;
  canvasFrameEncoderBindPipelineCount: number;
  canvasFrameEncoderDrawBatchCount: number;
  canvasFramePipelineCount: number;
  canvasFramePipelineUploadCount: number;
  canvasFramePipelineRetainCount: number;
  canvasFramePipelineEvictCount: number;
  canvasFrameResourceCount: number;
  canvasFrameResourceUploadCount: number;
  canvasFrameResourceRetainCount: number;
  canvasFrameResourceEvictCount: number;
  canvasFrameGlyphAtlasEntryCount: number;
  canvasFrameGlyphAtlasUploadCount: number;
  canvasFrameGlyphAtlasRetainCount: number;
  canvasFrameGlyphAtlasEvictCount: number;
  canvasFrameTextLayoutCount: number;
  canvasFrameTextLayoutLineCount: number;
  canvasFrameTextLayoutUploadCount: number;
  canvasFrameTextLayoutRetainCount: number;
  canvasFrameTextLayoutEvictCount: number;
  canvasFrameChangeCount: number;
  canvasFrameBudgetExceededCount: number;
  canvasFrameBudgetOk: boolean;
  canvasFrameDirtyBounds: ZeroNativeRect | null;
  focused: boolean;
  command: string;
  open: boolean;
}

export type ZeroNativeNativeViewKind = Exclude<ZeroNativeViewKind, "webview">;

export interface ZeroNativeCreateViewBaseOptions {
  label: string;
  windowId?: number;
  parent?: string;
  layer?: number;
  visible?: boolean;
  enabled?: boolean;
  /** Semantic role or fallback accessibility text. Use text for visible titles and placeholders. */
  role?: string;
  /** Accessibility label announced for the native control without changing visible text. */
  accessibilityLabel?: string;
  /** Visible native control label, button title, or text/search placeholder. */
  text?: string;
  command?: string;
  transparent?: boolean;
  bridge?: boolean;
}

export interface ZeroNativeCreateNativeViewOptions extends ZeroNativeCreateViewBaseOptions {
  kind: ZeroNativeNativeViewKind;
  frame?: ZeroNativeRect;
  url?: never;
}

export interface ZeroNativeCreateWebViewViewOptions extends ZeroNativeCreateViewBaseOptions {
  kind: "webview";
  frame: ZeroNativeRect;
  url: string;
}

export type ZeroNativeCreateViewOptions =
  | ZeroNativeCreateNativeViewOptions
  | ZeroNativeCreateWebViewViewOptions;

export interface ZeroNativeUpdateViewOptions {
  label: string;
  windowId?: number;
  frame?: ZeroNativeRect;
  layer?: number;
  visible?: boolean;
  enabled?: boolean;
  /** Semantic role or fallback accessibility text. Use text for visible titles and placeholders. */
  role?: string;
  /** Accessibility label announced for the native control without changing visible text. */
  accessibilityLabel?: string;
  /** Visible native control label, button title, or text/search placeholder. */
  text?: string;
  command?: string;
  /** Only valid for WebView-backed views. */
  url?: string;
}

export interface ZeroNativeSetViewFrameOptions {
  label: string;
  windowId?: number;
  frame: ZeroNativeRect;
}

export interface ZeroNativeSetViewVisibleOptions {
  label: string;
  windowId?: number;
  visible: boolean;
}

export interface ZeroNativeViewSelector {
  label: string;
  windowId?: number;
}

export interface ZeroNativeViewTraversalOptions {
  windowId?: number;
}

export interface ZeroNativeViewHandle extends ZeroNativeViewInfo {
  update(patch: Omit<ZeroNativeUpdateViewOptions, "label" | "windowId">): Promise<ZeroNativeViewHandle>;
  setFrame(frame: ZeroNativeRect): Promise<ZeroNativeViewHandle>;
  setVisible(visible: boolean): Promise<ZeroNativeViewHandle>;
  focus(): Promise<ZeroNativeViewHandle>;
  close(): Promise<ZeroNativeViewInfo>;
}

export type ZeroNativeCommandSource =
  | "runtime"
  | "menu"
  | "shortcut"
  | "toolbar"
  | "tray"
  | "native_view"
  | "bridge";

export type ZeroNativePlatformFeature =
  | "main_webview"
  | "mainWebView"
  | "child_webviews"
  | "childWebViews"
  | "native_views"
  | "nativeViews"
  | "native_control_commands"
  | "nativeControlCommands"
  | "menus"
  | "tray"
  | "shortcuts"
  | "dialogs"
  | "clipboard_text"
  | "clipboardText"
  | "clipboard_rich_data"
  | "clipboardRichData"
  | "open_url"
  | "openUrl"
  | "reveal_path"
  | "revealPath"
  | "notifications"
  | "recent_documents"
  | "recentDocuments"
  | "credentials"
  | "file_drops"
  | "fileDrops"
  | "app_activation_events"
  | "appActivationEvents"
  | "gpu_surfaces"
  | "gpuSurfaces";

export type ZeroNativePlatformFeatureSelector =
  | { feature: ZeroNativePlatformFeature; name?: never }
  | { feature?: never; name: ZeroNativePlatformFeature };

export interface ZeroNativeCommandEvent {
  name: string;
  source: ZeroNativeCommandSource;
  windowId: number;
  viewLabel: string;
  /** Native tray item id for tray-sourced commands, otherwise 0. */
  trayItemId: number;
}

export interface ZeroNativeCommandInfo {
  id: string;
  title: string;
  enabled: boolean;
  checked: boolean;
}

export interface ZeroNativeCommandSelector {
  name?: string;
  id?: string;
}

export interface ZeroNativeShortcutModifiers {
  primary: boolean;
  command: boolean;
  control: boolean;
  option: boolean;
  shift: boolean;
}

export interface ZeroNativeShortcutDetail {
  id: string;
  /** Alias for `id`, kept for compatibility with older built-in shortcut events. */
  command: string;
  key: string;
  windowId: number;
  modifiers: ZeroNativeShortcutModifiers;
}

export type ZeroNativeAppLifecycleDetail = Record<string, never>;

export interface ZeroNativeFileDropDetail {
  windowId: number;
  paths: string[];
}

export interface ZeroNativeOpenFileOptions {
  title?: string;
  defaultPath?: string;
  allowDirectories?: boolean;
  allowMultiple?: boolean;
}

export interface ZeroNativeSaveFileOptions {
  title?: string;
  defaultPath?: string;
  defaultName?: string;
}

export interface ZeroNativeMessageDialogOptions {
  style?: "info" | "warning" | "critical";
  title?: string;
  message?: string;
  informativeText?: string;
  primaryButton?: string;
  secondaryButton?: string;
  tertiaryButton?: string;
}

export interface ZeroNativeOpenUrlOptions {
  url: string;
}

export interface ZeroNativeRevealPathOptions {
  path: string;
}

export interface ZeroNativeRecentDocumentOptions {
  path: string;
}

export interface ZeroNativeNotificationOptions {
  title: string;
  subtitle?: string;
  body?: string;
}

export interface ZeroNativeClipboardReadOptions {
  mimeType?: string;
}

export interface ZeroNativeClipboardWriteOptions {
  mimeType?: string;
  data: string;
}

export interface ZeroNativeClipboardData {
  mimeType: string;
  data: string;
}

export interface ZeroNativeCredentialKey {
  service: string;
  account: string;
}

export interface ZeroNativeSetCredentialOptions extends ZeroNativeCredentialKey {
  secret: string;
}

export interface ZeroNativeApi {
  invoke<T = ZeroNativeJson>(command: string, payload?: ZeroNativeJson): Promise<T>;
  on(name: "shortcut", callback: (detail: ZeroNativeShortcutDetail) => void): () => void;
  on(name: "app:activate" | "app:deactivate", callback: (detail: ZeroNativeAppLifecycleDetail) => void): () => void;
  on(name: "drop:files", callback: (detail: ZeroNativeFileDropDetail) => void): () => void;
  on<T = ZeroNativeJson>(name: string, callback: (detail: T) => void): () => void;
  off(name: "shortcut", callback: (detail: ZeroNativeShortcutDetail) => void): void;
  off(name: "app:activate" | "app:deactivate", callback: (detail: ZeroNativeAppLifecycleDetail) => void): void;
  off(name: "drop:files", callback: (detail: ZeroNativeFileDropDetail) => void): void;
  off<T = ZeroNativeJson>(name: string, callback: (detail: T) => void): void;
  /** Dispatch an app command through the runtime command path. */
  commands: {
    invoke(command: string | ZeroNativeCommandSelector): Promise<ZeroNativeCommandEvent>;
    list(): Promise<ZeroNativeCommandInfo[]>;
  };
  windows: {
    create(options?: ZeroNativeCreateWindowOptions): Promise<ZeroNativeWindowInfo>;
    list(): Promise<ZeroNativeWindowInfo[]>;
    focus(value: number | string): Promise<ZeroNativeWindowInfo>;
    close(value: number | string): Promise<ZeroNativeWindowInfo>;
  };
  /** Manage the named native WebViews layered inside the calling native window. */
  webviews: {
    create(options: ZeroNativeCreateWebViewOptions): Promise<ZeroNativeWebViewHandle>;
    list(): Promise<ZeroNativeWebViewInfo[]>;
    setFrame(options: ZeroNativeSetWebViewFrameOptions): Promise<ZeroNativeWebViewInfo>;
    navigate(options: ZeroNativeNavigateWebViewOptions): Promise<ZeroNativeWebViewInfo>;
    setZoom(options: ZeroNativeSetWebViewZoomOptions): Promise<ZeroNativeWebViewInfo>;
    setLayer(options: ZeroNativeSetWebViewLayerOptions): Promise<ZeroNativeWebViewInfo>;
    close(options?: ZeroNativeCloseWebViewOptions): Promise<ZeroNativeWebViewInfo>;
  };
  /** Manage generic native views and WebView-backed views inside the calling native window. */
  views: {
    create(options: ZeroNativeCreateViewOptions): Promise<ZeroNativeViewHandle>;
    list(): Promise<ZeroNativeViewInfo[]>;
    update(label: string, patch: Omit<ZeroNativeUpdateViewOptions, "label" | "windowId">): Promise<ZeroNativeViewHandle>;
    update(options: ZeroNativeUpdateViewOptions): Promise<ZeroNativeViewHandle>;
    setFrame(options: ZeroNativeSetViewFrameOptions): Promise<ZeroNativeViewHandle>;
    setVisible(options: ZeroNativeSetViewVisibleOptions): Promise<ZeroNativeViewHandle>;
    focus(options: string | ZeroNativeViewSelector): Promise<ZeroNativeViewHandle>;
    focusNext(options?: ZeroNativeViewTraversalOptions): Promise<ZeroNativeViewHandle>;
    focusPrevious(options?: ZeroNativeViewTraversalOptions): Promise<ZeroNativeViewHandle>;
    close(options: string | ZeroNativeViewSelector): Promise<ZeroNativeViewInfo>;
  };
  dialogs: {
    openFile(options?: ZeroNativeOpenFileOptions): Promise<string[] | null>;
    saveFile(options?: ZeroNativeSaveFileOptions): Promise<string | null>;
    showMessage(options?: ZeroNativeMessageDialogOptions): Promise<"primary" | "secondary" | "tertiary">;
  };
  clipboard: {
    readText(): Promise<string>;
    writeText(value: string | { text: string }): Promise<boolean>;
    read(options?: ZeroNativeClipboardReadOptions): Promise<ZeroNativeClipboardData>;
    write(options: string | ZeroNativeClipboardWriteOptions): Promise<boolean>;
  };
  os: {
    openUrl(value: string | ZeroNativeOpenUrlOptions): Promise<boolean>;
    showNotification(value: string | ZeroNativeNotificationOptions): Promise<boolean>;
    revealPath(value: string | ZeroNativeRevealPathOptions): Promise<boolean>;
    addRecentDocument(value: string | ZeroNativeRecentDocumentOptions): Promise<boolean>;
    clearRecentDocuments(): Promise<boolean>;
  };
  credentials: {
    set(options: ZeroNativeSetCredentialOptions): Promise<boolean>;
    get(options: ZeroNativeCredentialKey): Promise<string | null>;
    delete(options: ZeroNativeCredentialKey): Promise<boolean>;
  };
  platform: {
    supports(value: ZeroNativePlatformFeature | ZeroNativePlatformFeatureSelector): Promise<boolean>;
  };
}

declare global {
  interface Window {
    zero: ZeroNativeApi;
  }
}

export {};

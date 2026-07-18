export type NativeSdkJson =
  | null
  | boolean
  | number
  | string
  | NativeSdkJson[]
  | { [key: string]: NativeSdkJson };

export type NativeSdkErrorCode =
  | "invalid_request"
  | "unknown_command"
  | "permission_denied"
  | "handler_failed"
  | "payload_too_large"
  | "internal_error"
  | string;

export interface NativeSdkInvokeError extends Error {
  code: NativeSdkErrorCode;
}

export interface NativeSdkWindowInfo {
  id: number;
  label: string;
  title: string;
  open: boolean;
  focused: boolean;
  /** Alive but hidden by `close_policy = "hide"` — still open, not focused, invisible until re-shown. */
  hidden: boolean;
  x: number;
  y: number;
  width: number;
  height: number;
  scale: number;
}

export interface NativeSdkCreateWindowOptions {
  label?: string;
  title?: string;
  width?: number;
  height?: number;
  x?: number;
  y?: number;
  restoreState?: boolean;
  url?: string;
}

export interface NativeSdkRect {
  x?: number;
  y?: number;
  width: number;
  height: number;
}

export interface NativeSdkWebViewInfo {
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

export interface NativeSdkCreateWebViewOptions {
  /** Stable label for this child WebView. Defaults to "webview". Unique per native window. "main" is reserved for the startup WebView. */
  label?: string;
  /** Parent native window id. Defaults to the caller and must match the window that calls the command when provided. */
  windowId?: number;
  /** Target URL. Its origin must be listed in the runtime navigation policy. */
  url: string;
  /** Logical content coordinates relative to the parent window. */
  frame: NativeSdkRect;
  /** Native z-order within the parent window. Higher layers appear above lower layers. */
  layer?: number;
  /** Best-effort transparent WebView background support for chrome/menu surfaces. */
  transparent?: boolean;
  /** Inject `window.zero` into this WebView when it is trusted app chrome. Defaults to false. */
  bridge?: boolean;
}

export interface NativeSdkSetWebViewFrameOptions {
  /** Defaults to "webview". Use "main" to resize the startup WebView. */
  label?: string;
  /** Defaults to the caller and must match the window that calls the command when provided. */
  windowId?: number;
  frame: NativeSdkRect;
}

export interface NativeSdkNavigateWebViewOptions {
  /** Defaults to "webview". Child WebViews only. */
  label?: string;
  /** Defaults to the caller and must match the window that calls the command when provided. */
  windowId?: number;
  url: string;
}

export interface NativeSdkSetWebViewZoomOptions {
  /** Defaults to "webview". Use "main" to zoom the startup WebView. */
  label?: string;
  /** Defaults to the caller and must match the window that calls the command when provided. */
  windowId?: number;
  /** Page zoom factor. Valid range: 0.25 to 5.0. */
  zoom: number;
}

export interface NativeSdkSetWebViewLayerOptions {
  /** Defaults to "webview". "main" support depends on the native backend. */
  label?: string;
  /** Defaults to the caller and must match the window that calls the command when provided. */
  windowId?: number;
  layer: number;
}

export interface NativeSdkCloseWebViewOptions {
  /** Defaults to "webview". The reserved "main" WebView cannot be closed. */
  label?: string;
  /** Defaults to the caller and must match the window that calls the command when provided. */
  windowId?: number;
}

export interface NativeSdkWebViewHandle extends NativeSdkWebViewInfo {
  setFrame(frame: NativeSdkRect): Promise<NativeSdkWebViewInfo>;
  navigate(url: string): Promise<NativeSdkWebViewInfo>;
  setZoom(zoom: number): Promise<NativeSdkWebViewInfo>;
  setLayer(layer: number): Promise<NativeSdkWebViewInfo>;
  close(): Promise<NativeSdkWebViewInfo>;
}

export type NativeSdkViewKind =
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

export type NativeSdkGpuSurfaceBackend = "none" | "metal";
export type NativeSdkGpuSurfacePixelFormat = "none" | "bgra8_unorm";
export type NativeSdkGpuSurfacePresentMode = "none" | "timer";
export type NativeSdkGpuSurfaceAlphaMode = "none" | "opaque" | "premultiplied";
export type NativeSdkGpuSurfaceColorSpace = "none" | "srgb" | "display_p3";
export type NativeSdkGpuSurfaceStatus = "unavailable" | "initializing" | "ready" | "lost";
export type NativeSdkCursor = "arrow" | "pointing_hand" | "text" | "resize_horizontal";
export type NativeSdkCanvasFrameProfileRisk = "idle" | "low" | "moderate" | "high";

export interface NativeSdkViewInfo {
  /** Stable runtime view id for this window/view lifetime. */
  id: number;
  label: string;
  windowId: number;
  kind: NativeSdkViewKind;
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
  gpuFrameIntervalNs: number;
  gpuInputTimestampNs: number;
  gpuInputLatencyNs: number;
  gpuInputLatencyBudgetNs: number;
  gpuInputLatencyBudgetExceededCount: number;
  gpuInputLatencyBudgetOk: boolean;
  gpuFirstFrameLatencyNs: number;
  gpuFirstFrameLatencyBudgetNs: number;
  gpuFirstFrameLatencyBudgetExceededCount: number;
  gpuFirstFrameLatencyBudgetOk: boolean;
  gpuNonblank: boolean;
  gpuSampleColor: number;
  gpuBackend: NativeSdkGpuSurfaceBackend;
  gpuPixelFormat: NativeSdkGpuSurfacePixelFormat;
  gpuPresentMode: NativeSdkGpuSurfacePresentMode;
  gpuAlphaMode: NativeSdkGpuSurfaceAlphaMode;
  gpuColorSpace: NativeSdkGpuSurfaceColorSpace;
  gpuVsync: boolean;
  gpuStatus: NativeSdkGpuSurfaceStatus;
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
  canvasFramePathGeometryCount: number;
  canvasFramePathGeometryVertexCount: number;
  canvasFramePathGeometryIndexCount: number;
  canvasFramePathGeometryUploadCount: number;
  canvasFramePathGeometryRetainCount: number;
  canvasFramePathGeometryEvictCount: number;
  canvasFrameImageCount: number;
  canvasFrameImageUploadCount: number;
  canvasFrameImageRetainCount: number;
  canvasFrameImageEvictCount: number;
  canvasFrameLayerCount: number;
  canvasFrameLayerOpacityCount: number;
  canvasFrameLayerClipCount: number;
  canvasFrameLayerTransformCount: number;
  canvasFrameLayerUploadCount: number;
  canvasFrameLayerRetainCount: number;
  canvasFrameLayerEvictCount: number;
  canvasFrameResourceCount: number;
  canvasFrameResourceUploadCount: number;
  canvasFrameResourceRetainCount: number;
  canvasFrameResourceEvictCount: number;
  canvasFrameVisualEffectCount: number;
  canvasFrameVisualEffectShadowCount: number;
  canvasFrameVisualEffectBlurCount: number;
  canvasFrameVisualEffectUploadCount: number;
  canvasFrameVisualEffectRetainCount: number;
  canvasFrameVisualEffectEvictCount: number;
  canvasFrameGlyphAtlasEntryCount: number;
  canvasFrameGlyphAtlasUploadCount: number;
  canvasFrameGlyphAtlasRetainCount: number;
  canvasFrameGlyphAtlasEvictCount: number;
  canvasFrameTextLayoutCount: number;
  canvasFrameTextLayoutLineCount: number;
  canvasFrameTextLayoutUploadCount: number;
  canvasFrameTextLayoutRetainCount: number;
  canvasFrameTextLayoutEvictCount: number;
  canvasFrameGpuPacketCommandCount: number;
  canvasFrameGpuPacketCacheActionCount: number;
  canvasFrameGpuPacketCachedResourceCommandCount: number;
  canvasFrameGpuPacketUnsupportedCommandCount: number;
  canvasFrameGpuPacketRepresentable: boolean;
  canvasFrameChangeCount: number;
  canvasFrameBudgetExceededCount: number;
  canvasFrameBudgetOk: boolean;
  canvasFrameDirtyBounds: NativeSdkRect | null;
  canvasFrameProfileWorkUnits: number;
  canvasFrameProfileRisk: NativeSdkCanvasFrameProfileRisk;
  canvasFrameProfileSurfaceArea: number;
  canvasFrameProfileDirtyArea: number;
  canvasFrameProfileDirtyRatio: number;
  widgetRevision: number;
  widgetNodeCount: number;
  widgetSemanticsCount: number;
  cursor: NativeSdkCursor;
  focused: boolean;
  command: string;
  open: boolean;
}

export type NativeSdkNativeViewKind = Exclude<NativeSdkViewKind, "webview">;

export interface NativeSdkCreateViewBaseOptions {
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

export interface NativeSdkCreateNativeViewOptions extends NativeSdkCreateViewBaseOptions {
  kind: NativeSdkNativeViewKind;
  frame?: NativeSdkRect;
  url?: never;
  /** Only valid for gpu_surface views. Defaults to the first supported backend. */
  gpuBackend?: NativeSdkGpuSurfaceBackend;
  /** Only valid for gpu_surface views. */
  gpuPixelFormat?: NativeSdkGpuSurfacePixelFormat;
  /** Only valid for gpu_surface views. */
  gpuPresentMode?: NativeSdkGpuSurfacePresentMode;
  /** Only valid for gpu_surface views. */
  gpuAlphaMode?: NativeSdkGpuSurfaceAlphaMode;
  /** Only valid for gpu_surface views. */
  gpuColorSpace?: NativeSdkGpuSurfaceColorSpace;
  /** Only valid for gpu_surface views. */
  gpuVsync?: boolean;
}

export interface NativeSdkCreateWebViewViewOptions extends NativeSdkCreateViewBaseOptions {
  kind: "webview";
  frame: NativeSdkRect;
  url: string;
}

export type NativeSdkCreateViewOptions =
  | NativeSdkCreateNativeViewOptions
  | NativeSdkCreateWebViewViewOptions;

export interface NativeSdkUpdateViewOptions {
  label: string;
  windowId?: number;
  frame?: NativeSdkRect;
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

export interface NativeSdkSetViewFrameOptions {
  label: string;
  windowId?: number;
  frame: NativeSdkRect;
}

export interface NativeSdkSetViewVisibleOptions {
  label: string;
  windowId?: number;
  visible: boolean;
}

export interface NativeSdkViewSelector {
  label: string;
  windowId?: number;
}

export interface NativeSdkViewTraversalOptions {
  windowId?: number;
}

export interface NativeSdkViewHandle extends NativeSdkViewInfo {
  update(patch: Omit<NativeSdkUpdateViewOptions, "label" | "windowId">): Promise<NativeSdkViewHandle>;
  setFrame(frame: NativeSdkRect): Promise<NativeSdkViewHandle>;
  setVisible(visible: boolean): Promise<NativeSdkViewHandle>;
  focus(): Promise<NativeSdkViewHandle>;
  close(): Promise<NativeSdkViewInfo>;
}

export type NativeSdkCommandSource =
  | "runtime"
  | "menu"
  | "shortcut"
  | "toolbar"
  | "tray"
  | "native_view"
  | "bridge";

export type NativeSdkPlatformFeature =
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

export type NativeSdkPlatformFeatureSelector =
  | { feature: NativeSdkPlatformFeature; name?: never }
  | { feature?: never; name: NativeSdkPlatformFeature };

export interface NativeSdkCommandEvent {
  name: string;
  source: NativeSdkCommandSource;
  windowId: number;
  viewLabel: string;
  /** Native tray item id for tray-sourced commands, otherwise 0. */
  trayItemId: number;
}

export interface NativeSdkCommandInfo {
  id: string;
  title: string;
  enabled: boolean;
  checked: boolean;
}

export interface NativeSdkCommandSelector {
  name?: string;
  id?: string;
}

export interface NativeSdkShortcutModifiers {
  primary: boolean;
  command: boolean;
  control: boolean;
  option: boolean;
  shift: boolean;
}

export interface NativeSdkShortcutDetail {
  id: string;
  /** Alias for `id`, kept for compatibility with older built-in shortcut events. */
  command: string;
  key: string;
  windowId: number;
  modifiers: NativeSdkShortcutModifiers;
}

export type NativeSdkAppLifecycleDetail = Record<string, never>;

export interface NativeSdkFileDropDetail {
  windowId: number;
  paths: string[];
}

export interface NativeSdkOpenFileOptions {
  title?: string;
  defaultPath?: string;
  allowDirectories?: boolean;
  allowMultiple?: boolean;
}

export interface NativeSdkSaveFileOptions {
  title?: string;
  defaultPath?: string;
  defaultName?: string;
}

export interface NativeSdkMessageDialogOptions {
  style?: "info" | "warning" | "critical";
  title?: string;
  message?: string;
  informativeText?: string;
  primaryButton?: string;
  secondaryButton?: string;
  tertiaryButton?: string;
}

export interface NativeSdkOpenUrlOptions {
  url: string;
}

export interface NativeSdkRevealPathOptions {
  path: string;
}

export interface NativeSdkRecentDocumentOptions {
  path: string;
}

export interface NativeSdkNotificationOptions {
  title: string;
  subtitle?: string;
  body?: string;
}

export interface NativeSdkClipboardReadOptions {
  mimeType?: string;
}

export interface NativeSdkClipboardWriteOptions {
  mimeType?: string;
  data: string;
}

export interface NativeSdkClipboardData {
  mimeType: string;
  data: string;
}

export interface NativeSdkCredentialKey {
  service: string;
  account: string;
}

export interface NativeSdkSetCredentialOptions extends NativeSdkCredentialKey {
  secret: string;
}

export interface NativeSdkApi {
  invoke<T = NativeSdkJson>(command: string, payload?: NativeSdkJson): Promise<T>;
  on(name: "shortcut", callback: (detail: NativeSdkShortcutDetail) => void): () => void;
  on(name: "app:activate" | "app:deactivate", callback: (detail: NativeSdkAppLifecycleDetail) => void): () => void;
  on(name: "drop:files", callback: (detail: NativeSdkFileDropDetail) => void): () => void;
  on<T = NativeSdkJson>(name: string, callback: (detail: T) => void): () => void;
  off(name: "shortcut", callback: (detail: NativeSdkShortcutDetail) => void): void;
  off(name: "app:activate" | "app:deactivate", callback: (detail: NativeSdkAppLifecycleDetail) => void): void;
  off(name: "drop:files", callback: (detail: NativeSdkFileDropDetail) => void): void;
  off<T = NativeSdkJson>(name: string, callback: (detail: T) => void): void;
  /** Dispatch an app command through the runtime command path. */
  commands: {
    invoke(command: string | NativeSdkCommandSelector): Promise<NativeSdkCommandEvent>;
    list(): Promise<NativeSdkCommandInfo[]>;
  };
  windows: {
    create(options?: NativeSdkCreateWindowOptions): Promise<NativeSdkWindowInfo>;
    list(): Promise<NativeSdkWindowInfo[]>;
    focus(value: number | string): Promise<NativeSdkWindowInfo>;
    close(value: number | string): Promise<NativeSdkWindowInfo>;
  };
  /** Manage the named native WebViews layered inside the calling native window. */
  webviews: {
    create(options: NativeSdkCreateWebViewOptions): Promise<NativeSdkWebViewHandle>;
    list(): Promise<NativeSdkWebViewInfo[]>;
    setFrame(options: NativeSdkSetWebViewFrameOptions): Promise<NativeSdkWebViewInfo>;
    navigate(options: NativeSdkNavigateWebViewOptions): Promise<NativeSdkWebViewInfo>;
    setZoom(options: NativeSdkSetWebViewZoomOptions): Promise<NativeSdkWebViewInfo>;
    setLayer(options: NativeSdkSetWebViewLayerOptions): Promise<NativeSdkWebViewInfo>;
    close(options?: NativeSdkCloseWebViewOptions): Promise<NativeSdkWebViewInfo>;
  };
  /** Manage generic native views and WebView-backed views inside the calling native window. */
  views: {
    create(options: NativeSdkCreateViewOptions): Promise<NativeSdkViewHandle>;
    list(): Promise<NativeSdkViewInfo[]>;
    update(label: string, patch: Omit<NativeSdkUpdateViewOptions, "label" | "windowId">): Promise<NativeSdkViewHandle>;
    update(options: NativeSdkUpdateViewOptions): Promise<NativeSdkViewHandle>;
    setFrame(options: NativeSdkSetViewFrameOptions): Promise<NativeSdkViewHandle>;
    setVisible(options: NativeSdkSetViewVisibleOptions): Promise<NativeSdkViewHandle>;
    focus(options: string | NativeSdkViewSelector): Promise<NativeSdkViewHandle>;
    focusNext(options?: NativeSdkViewTraversalOptions): Promise<NativeSdkViewHandle>;
    focusPrevious(options?: NativeSdkViewTraversalOptions): Promise<NativeSdkViewHandle>;
    close(options: string | NativeSdkViewSelector): Promise<NativeSdkViewInfo>;
  };
  dialogs: {
    openFile(options?: NativeSdkOpenFileOptions): Promise<string[] | null>;
    saveFile(options?: NativeSdkSaveFileOptions): Promise<string | null>;
    showMessage(options?: NativeSdkMessageDialogOptions): Promise<"primary" | "secondary" | "tertiary">;
  };
  clipboard: {
    readText(): Promise<string>;
    writeText(value: string | { text: string }): Promise<boolean>;
    read(options?: NativeSdkClipboardReadOptions): Promise<NativeSdkClipboardData>;
    write(options: string | NativeSdkClipboardWriteOptions): Promise<boolean>;
  };
  os: {
    openUrl(value: string | NativeSdkOpenUrlOptions): Promise<boolean>;
    showNotification(value: string | NativeSdkNotificationOptions): Promise<boolean>;
    revealPath(value: string | NativeSdkRevealPathOptions): Promise<boolean>;
    addRecentDocument(value: string | NativeSdkRecentDocumentOptions): Promise<boolean>;
    clearRecentDocuments(): Promise<boolean>;
  };
  credentials: {
    set(options: NativeSdkSetCredentialOptions): Promise<boolean>;
    get(options: NativeSdkCredentialKey): Promise<string | null>;
    delete(options: NativeSdkCredentialKey): Promise<boolean>;
  };
  platform: {
    supports(value: NativeSdkPlatformFeature | NativeSdkPlatformFeatureSelector): Promise<boolean>;
  };
}

declare global {
  interface Window {
    zero: NativeSdkApi;
  }
}

export {};

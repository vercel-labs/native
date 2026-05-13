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
  titleBarStyle?: "standard" | "overlay";
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

export interface ZeroNativeApi {
  invoke<T = ZeroNativeJson>(command: string, payload?: ZeroNativeJson): Promise<T>;
  on<T = ZeroNativeJson>(name: string, callback: (detail: T) => void): () => void;
  off<T = ZeroNativeJson>(name: string, callback: (detail: T) => void): void;
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
  dialogs: {
    openFile(options?: ZeroNativeOpenFileOptions): Promise<string[] | null>;
    saveFile(options?: ZeroNativeSaveFileOptions): Promise<string | null>;
    showMessage(options?: ZeroNativeMessageDialogOptions): Promise<"primary" | "secondary" | "tertiary">;
  };
}

declare global {
  interface Window {
    zero: ZeroNativeApi;
  }
}

export {};

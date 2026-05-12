export type ZeroNativeJson =
  | null
  | boolean
  | number
  | string
  | ZeroNativeJson[]
  | { [key: string]: ZeroNativeJson };

export interface ZeroNativeResourceDescriptor {
  kind: "resource";
  id: string;
  url: string;
  mime: string;
  name?: string;
  size?: number;
  oneShot?: boolean;
}

export type ZeroNativeInvokeResult = ZeroNativeJson | ZeroNativeResourceDescriptor;

export interface ZeroNativeInvokeError extends Error {
  code: "invalid_request" | "unknown_command" | "permission_denied" | "handler_failed" | "payload_too_large" | "internal_error" | string;
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
  invoke<T = ZeroNativeInvokeResult>(command: string, payload?: ZeroNativeJson): Promise<T>;
  on<T = ZeroNativeJson>(name: string, callback: (detail: T) => void): () => void;
  off<T = ZeroNativeJson>(name: string, callback: (detail: T) => void): void;
  windows: {
    create(options?: ZeroNativeCreateWindowOptions): Promise<ZeroNativeWindowInfo>;
    list(): Promise<ZeroNativeWindowInfo[]>;
    focus(value: number | string): Promise<ZeroNativeWindowInfo>;
    close(value: number | string): Promise<ZeroNativeWindowInfo>;
  };
  dialogs: {
    openFile(options?: ZeroNativeOpenFileOptions): Promise<string[] | null>;
    saveFile(options?: ZeroNativeSaveFileOptions): Promise<string | null>;
    showMessage(options?: ZeroNativeMessageDialogOptions): Promise<"primary" | "secondary" | "tertiary">;
  };
  resources: {
    isDescriptor(value: unknown): value is ZeroNativeResourceDescriptor;
    url(resource: string | ZeroNativeResourceDescriptor): string;
    fetch(resource: string | ZeroNativeResourceDescriptor, init?: RequestInit): Promise<Response>;
    arrayBuffer(resource: string | ZeroNativeResourceDescriptor, init?: RequestInit): Promise<ArrayBuffer>;
    blob(resource: string | ZeroNativeResourceDescriptor, init?: RequestInit): Promise<Blob>;
    stream(resource: string | ZeroNativeResourceDescriptor, init?: RequestInit): Promise<ReadableStream<Uint8Array> | null>;
  };
}

declare global {
  interface Window {
    zero: ZeroNativeApi;
  }
}

export {};

/**
 * Loader + thin typed wrapper for the live component-preview engine:
 * the Native SDK canvas runtime compiled to wasm32-freestanding
 * (`zig build docs-wasm-preview` → /public/wasm/component-preview.wasm).
 *
 * One wasm instance is shared by every preview on the page; each
 * preview is an engine-side handle (its own retained runtime + scene).
 * The module has zero imports — the page owns the clock and the canvas,
 * and `render` reports whether the retained display list actually
 * changed so an idle preview never repaints or blits.
 */

interface PreviewExports {
  memory: WebAssembly.Memory;
  preview_alloc(len: number): number;
  preview_free(ptr: number, len: number): void;
  preview_instance_bytes(): number;
  preview_set_now_ms(ms: number): void;
  preview_create(namePtr: number, nameLen: number, dark: number): number;
  preview_destroy(handle: number): void;
  preview_logical_width(handle: number): number;
  preview_logical_height(handle: number): number;
  preview_set_theme(handle: number, dark: number): number;
  preview_pointer(handle: number, kind: number, x: number, y: number): void;
  preview_scroll(handle: number, x: number, y: number, dx: number, dy: number): void;
  preview_key(
    handle: number,
    phase: number,
    keyPtr: number,
    keyLen: number,
    textPtr: number,
    textLen: number,
    modifiers: number,
  ): void;
  preview_text(handle: number, textPtr: number, textLen: number): void;
  preview_text_input_active(handle: number): number;
  preview_frame(handle: number): void;
  preview_pixel_width(handle: number, scale: number): number;
  preview_pixel_height(handle: number, scale: number): number;
  preview_pixel_byte_len(handle: number, scale: number): number;
  preview_render(
    handle: number,
    scale: number,
    pixelsPtr: number,
    pixelsLen: number,
    scratchPtr: number,
    scratchLen: number,
  ): number;
}

export const PointerKind = {
  down: 0,
  up: 1,
  move: 2,
  drag: 3,
  cancel: 4,
} as const;

const encoder = new TextEncoder();

export class PreviewEngine {
  constructor(private exports: PreviewExports) {}

  create(scene: string, dark: boolean): LivePreview | null {
    const e = this.exports;
    const bytes = encoder.encode(scene);
    const ptr = e.preview_alloc(bytes.length);
    if (!ptr) return null;
    new Uint8Array(e.memory.buffer).set(bytes, ptr);
    const handle = e.preview_create(ptr, bytes.length, dark ? 1 : 0);
    e.preview_free(ptr, bytes.length);
    if (!handle) return null;
    return new LivePreview(e, handle);
  }
}

export class LivePreview {
  readonly logicalWidth: number;
  readonly logicalHeight: number;
  private pixelsPtr = 0;
  private scratchPtr = 0;
  private bufferLen = 0;
  private imageData: ImageData | null = null;
  private destroyed = false;

  constructor(
    private exports: PreviewExports,
    private handle: number,
  ) {
    this.logicalWidth = exports.preview_logical_width(handle);
    this.logicalHeight = exports.preview_logical_height(handle);
  }

  setNow(ms: number): void {
    this.exports.preview_set_now_ms(ms);
  }

  pointer(kind: number, x: number, y: number): void {
    if (this.destroyed) return;
    this.exports.preview_pointer(this.handle, kind, x, y);
  }

  scroll(x: number, y: number, dx: number, dy: number): void {
    if (this.destroyed) return;
    this.exports.preview_scroll(this.handle, x, y, dx, dy);
  }

  key(phase: 0 | 1, key: string, text: string, modifiers: number): void {
    if (this.destroyed) return;
    const e = this.exports;
    const keyBytes = encoder.encode(key);
    const textBytes = encoder.encode(text);
    const len = keyBytes.length + textBytes.length;
    const ptr = len > 0 ? e.preview_alloc(len) : 0;
    if (len > 0 && !ptr) return;
    if (ptr) {
      const mem = new Uint8Array(e.memory.buffer);
      mem.set(keyBytes, ptr);
      mem.set(textBytes, ptr + keyBytes.length);
    }
    e.preview_key(this.handle, phase, ptr, keyBytes.length, ptr + keyBytes.length, textBytes.length, modifiers);
    if (ptr) e.preview_free(ptr, len);
  }

  text(value: string): void {
    if (this.destroyed) return;
    const e = this.exports;
    const bytes = encoder.encode(value);
    if (bytes.length === 0) return;
    const ptr = e.preview_alloc(bytes.length);
    if (!ptr) return;
    new Uint8Array(e.memory.buffer).set(bytes, ptr);
    e.preview_text(this.handle, ptr, bytes.length);
    e.preview_free(ptr, bytes.length);
  }

  textInputActive(): boolean {
    if (this.destroyed) return false;
    return this.exports.preview_text_input_active(this.handle) !== 0;
  }

  setTheme(dark: boolean): void {
    if (this.destroyed) return;
    this.exports.preview_set_theme(this.handle, dark ? 1 : 0);
  }

  /** Step engine-owned frame animations (scroll momentum). */
  frame(): void {
    if (this.destroyed) return;
    this.exports.preview_frame(this.handle);
  }

  pixelWidth(scale: number): number {
    return this.destroyed ? 0 : this.exports.preview_pixel_width(this.handle, scale);
  }

  pixelHeight(scale: number): number {
    return this.destroyed ? 0 : this.exports.preview_pixel_height(this.handle, scale);
  }

  /**
   * Render at `scale` device pixels per logical unit. Returns the fresh
   * ImageData when the engine repainted, or null when the retained scene
   * is unchanged (skip the blit) or on error.
   */
  render(scale: number): ImageData | null {
    if (this.destroyed) return null;
    const e = this.exports;
    const byteLen = e.preview_pixel_byte_len(this.handle, scale);
    if (!byteLen) return null;
    if (byteLen !== this.bufferLen) {
      this.releaseBuffers();
      this.pixelsPtr = e.preview_alloc(byteLen);
      this.scratchPtr = e.preview_alloc(byteLen);
      if (!this.pixelsPtr || !this.scratchPtr) {
        this.releaseBuffers();
        return null;
      }
      this.bufferLen = byteLen;
      this.imageData = null;
    }
    const status = e.preview_render(this.handle, scale, this.pixelsPtr, byteLen, this.scratchPtr, byteLen);
    if (status !== 1) return null;
    const width = e.preview_pixel_width(this.handle, scale);
    const height = e.preview_pixel_height(this.handle, scale);
    if (!width || !height) return null;
    if (!this.imageData || this.imageData.width !== width || this.imageData.height !== height) {
      this.imageData = new ImageData(width, height);
    }
    // Copy out of wasm memory: the buffer may move on memory growth, so
    // never hand long-lived views to the canvas.
    this.imageData.data.set(new Uint8ClampedArray(e.memory.buffer, this.pixelsPtr, byteLen));
    return this.imageData;
  }

  private releaseBuffers(): void {
    const e = this.exports;
    if (this.pixelsPtr) e.preview_free(this.pixelsPtr, this.bufferLen);
    if (this.scratchPtr) e.preview_free(this.scratchPtr, this.bufferLen);
    this.pixelsPtr = 0;
    this.scratchPtr = 0;
    this.bufferLen = 0;
    this.imageData = null;
  }

  destroy(): void {
    if (this.destroyed) return;
    this.releaseBuffers();
    this.exports.preview_destroy(this.handle);
    this.destroyed = true;
  }
}

let enginePromise: Promise<PreviewEngine | null> | null = null;

/**
 * Fetch + instantiate the shared engine once. Resolves null when wasm
 * is unavailable (the static webp layer simply stays).
 */
export function loadPreviewEngine(): Promise<PreviewEngine | null> {
  if (!enginePromise) {
    enginePromise = instantiate().catch(() => null);
  }
  return enginePromise;
}

async function instantiate(): Promise<PreviewEngine | null> {
  if (typeof WebAssembly === "undefined") return null;
  const url = "/wasm/component-preview.wasm";
  let instance: WebAssembly.Instance;
  try {
    const streamed = await WebAssembly.instantiateStreaming(fetch(url), {});
    instance = streamed.instance;
  } catch {
    // Older servers without the application/wasm MIME type.
    const response = await fetch(url);
    if (!response.ok) return null;
    const bytes = await response.arrayBuffer();
    const result = await WebAssembly.instantiate(bytes, {});
    instance = result.instance;
  }
  return new PreviewEngine(instance.exports as unknown as PreviewExports);
}

// Byte views for the DOM APIs that take a BufferSource, handed over as the plain buffer those
// APIs are specified to accept.
//
// The DOM's BlobPart is `BufferSource | Blob | string`, and a BufferSource is any
// ArrayBufferView or ArrayBuffer: where the bytes live behind the view doesn't matter to the
// platform, which reads them or copies them. TypeScript's lib.dom, since 5.7, spells a
// BufferSource as ArrayBufferView over a non-shared ArrayBuffer alone, so a `Uint8Array` (which
// is generic over its backing buffer) is refused by Blob, crypto.subtle and TextDecoder even
// though the spec and the runtime take it.

/** `bytes` as a view over a non-shared ArrayBuffer, which is the BufferSource these APIs are
 *  typed to want.
 *
 *  A view that already reads a plain ArrayBuffer keeps its bytes and its offsets: no copy is
 *  made. One that reads a SharedArrayBuffer is copied, since a DOM API that keeps the bytes
 *  (Blob does) must not keep a buffer another thread can still change. */
export function plainBytes(bytes: Uint8Array): Uint8Array<ArrayBuffer> {
  const buffer = bytes.buffer;
  if (buffer instanceof ArrayBuffer) return new Uint8Array(buffer, bytes.byteOffset, bytes.byteLength);
  const copy = new Uint8Array(bytes.length);
  copy.set(bytes);
  return copy;
}

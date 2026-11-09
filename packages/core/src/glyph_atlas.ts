// Build ordered atlas entries from copied draw-text facts. Glyph buffers and
// GPU resources stay native; no host pointer or precomputed key is accepted.
function nscvGlyphAtlasBucket(value: number): number {
  const fraction = Math.fround(value - Math.floor(value));
  const scaled = Math.floor(Math.fround(fraction * 4));
  // Zig's clamp uses minNum/maxNum, including the nonfinite case.
  return Number.isNaN(scaled) ? 3 : Math.max(0, Math.min(scaled, 3));
}
function nscvGlyphAtlasFallback(text: Uint8Array, first: number, last: number): number {
  const lead = text[first]!, length = (lead & 128) === 0 ? 1 : (lead & 224) === 192 ? 2 : (lead & 240) === 224 ? 3 : (lead & 248) === 240 ? 4 : 1;
  if (length === 1 || length > last - first) return lead;
  let value = lead & (length === 2 ? 31 : length === 3 ? 15 : 7);
  for (let i = 1; i < length; i++) { const byte = text[first + i]!; if ((byte & 192) !== 128) return lead; value = value * 64 + (byte & 63); }
  return value;
}
function nscvGlyphAtlasNext(text: Uint8Array, offset: number): number {
  let cursor = offset;
  while (cursor > 0 && (text[cursor]! & 192) === 128) cursor--;
  const byte = text[cursor]!, length = (byte & 128) === 0 ? 1 : (byte & 224) === 192 ? 2 : (byte & 240) === 224 ? 3 : (byte & 248) === 240 ? 4 : 1;
  const next = Math.min(text.length, cursor + length);
  return next <= offset ? Math.min(text.length, offset + 1) : next;
}
function nscvGlyphAtlasPlan(request: Uint8Array): Uint8Array {
  if (request.length < 16 || request[0] !== 61 || request[1] !== 1 || request[2] !== 0 || request[3] !== 0) throw new Error("invalid glyph atlas header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), runs = w.getUint32(4, true), capacity = w.getUint32(8, true);
  if (w.getUint32(12, true) !== 0 || runs > Math.floor((request.length - 16) / 40)) throw new Error("invalid glyph atlas runs");
  let payload = 16 + runs * 40, estimated = 0, lastCommand = -1;
  for (let i = 0; i < runs; i++) {
    const at = 16 + i * 40, command = w.getUint32(at, true), glyphs = w.getUint32(at + 28, true), bytes = w.getUint32(at + 32, true);
    if (command <= lastCommand || w.getUint32(at + 4, true) !== 0 || w.getUint32(at + 36, true) !== 0 || glyphs > Math.floor((request.length - payload) / 24)) throw new Error("invalid glyph atlas fact");
    for (let j = 0; j < glyphs; j++) if (w.getUint32(payload + j * 24 + 4, true) !== 0) throw new Error("invalid glyph atlas glyph");
    payload += glyphs * 24;
    if (bytes > request.length - payload) throw new Error("invalid glyph atlas text");
    payload += bytes; estimated += glyphs > 0 ? glyphs : bytes; lastCommand = command;
  }
  if (payload !== request.length) throw new Error("invalid glyph atlas storage");
  const output = new Uint8Array(16 + Math.min(capacity, estimated) * 32), out = new DataView(output.buffer);
  const indexed = estimated >= 64 && capacity <= 8192, heads = new Uint32Array(indexed ? 16384 : 0), next = new Uint32Array(indexed ? Math.min(capacity, estimated) : 0);
  const key = new Uint8Array(24), k = new DataView(key.buffer);
  let count = 0, failed = false;
  const equal = (index: number): boolean => {
    const at = 16 + index * 32;
    if (out.getFloat32(at, true) !== k.getFloat32(0, true)) return false;
    for (let i = 4; i < 24; i++) if (output[at + i] !== key[i]) return false;
    return true;
  };
  const append = (command: number, glyph: number): boolean => {
    const bucket = indexed ? nscvGlyphAtlasHash(k, 0) & 16383 : 0;
    if (indexed) { for (let stored = heads[bucket]!; stored > 0; stored = next[stored - 1]!) if (equal(stored - 1)) return true; }
    else for (let i = 0; i < count; i++) if (equal(i)) return true;
    if (count >= capacity) return false;
    const at = 16 + count * 32; output.set(key, at); out.setUint32(at + 24, command, true); out.setUint32(at + 28, glyph, true);
    if (indexed) { next[count] = heads[bucket]!; heads[bucket] = count + 1; }
    count++; return true;
  };
  payload = 16 + runs * 40;
  for (let i = 0; i < runs && !failed; i++) {
    const at = 16 + i * 40, command = w.getUint32(at, true), fontLow = w.getUint32(at + 8, true), fontHigh = w.getUint32(at + 12, true), size = w.getFloat32(at + 16, true);
    const x = w.getFloat32(at + 20, true), y = w.getFloat32(at + 24, true), glyphs = w.getUint32(at + 28, true), bytes = w.getUint32(at + 32, true);
    k.setUint32(0, w.getUint32(at + 16, true), true);
    if (glyphs > 0) {
      for (let j = 0; j < glyphs; j++) {
        const g = payload + j * 24, low = w.getUint32(g + 8, true), high = w.getUint32(g + 12, true), inherited = low === 0 && high === 0;
        k.setUint32(4, w.getUint32(g, true), true); k.setUint32(8, inherited ? fontLow : low, true); k.setUint32(12, inherited ? fontHigh : high, true);
        k.setUint32(16, nscvGlyphAtlasBucket(Math.fround(x + w.getFloat32(g + 16, true))), true); k.setUint32(20, nscvGlyphAtlasBucket(Math.fround(y + w.getFloat32(g + 20, true))), true);
        if (!append(command, j)) { failed = true; break; }
      }
    } else {
      const text = request.subarray(payload, payload + bytes); let first = 0, scalar = 0;
      while (first < bytes) {
        const last = nscvGlyphAtlasNext(text, first);
        const byte = text[first]!;
        if (byte !== 10 && byte !== 13 && byte !== 9 && byte !== 32) {
          k.setUint32(4, nscvGlyphAtlasFallback(text, first, last), true); k.setUint32(8, fontLow, true); k.setUint32(12, fontHigh, true);
          const offset = Math.fround(Math.fround(Math.fround(scalar) * size) * 0.5);
          k.setUint32(16, nscvGlyphAtlasBucket(Math.fround(x + offset)), true); k.setUint32(20, nscvGlyphAtlasBucket(y), true);
          if (!append(command, scalar)) { failed = true; break; }
        }
        first = last; scalar++;
      }
    }
    payload += glyphs * 24 + bytes;
  }
  out.setUint32(0, count, true); out.setUint32(4, failed ? 1 : 0, true);
  return output.slice(0, 16 + count * 32);
}

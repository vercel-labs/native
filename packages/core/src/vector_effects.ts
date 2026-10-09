// Derive vector geometry and effect resources from copied draw facts. Native
// retains source storage and GPU resources; this owner supplies complete plans.
class NscVectorHash {
  vector_hash_lower_word: number = 0x84222325;
  vector_hash_upper_word: number = 0xcbf29ce4;
  byte(value: number): void {
    const low = (this.vector_hash_lower_word ^ value) >>> 0, product = low * 435;
    this.vector_hash_upper_word = (this.vector_hash_upper_word * 435 + low * 256 + Math.floor(product / 4294967296)) >>> 0;
    this.vector_hash_lower_word = product >>> 0;
  }
  bytes(bytes: Uint8Array, at: number, length: number): void { for (let i = 0; i < length; i++) this.byte(bytes[at + i]!); }
  tag(value: string): void { const bytes = new TextEncoder().encode(value); this.bytes(bytes, 0, bytes.length); }
  word(value: number): void { for (let i = 0; i < 4; i++) this.byte((value >>> (i * 8)) & 255); }
  size(value: number): void { this.word(value); this.word(0); }
  float(value: number): void { const bytes = new Uint8Array(4); new DataView(bytes.buffer).setFloat32(0, value, true); this.bytes(bytes, 0, 4); }
  write(out: DataView, at: number): void { out.setUint32(at, this.vector_hash_lower_word, true); out.setUint32(at + 4, this.vector_hash_upper_word, true); }
}
// Preserve the copied target maxNum zero rule while owning the clamp.
function nscvVectorNonNegative(value: number, preserveZero: boolean): number { return value > 0 || (value === 0 && preserveZero) ? value : 0; }
function nscvVectorMax(a: number, b: number, rules: number): number {
  if (a === 0 && b === 0 && (1 / a < 0) !== (1 / b < 0)) return (rules & (1 / a < 0 ? 8 : 4)) !== 0 ? -0 : 0;
  return Number.isNaN(a) ? b : Number.isNaN(b) ? a : a > b ? a : b;
}
function nscvVectorEffects(request: Uint8Array): Uint8Array {
  if (request.length < 16 || request[0] !== 63 || request[1] !== 1 || request[2]! > 1 || request[3]! > 31) throw new Error("invalid vector resource header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), mode = request[2]!, rules = request[3]!;
  const count = w.getUint32(4, true), capacity = w.getUint32(8, true), stride = mode === 0 ? 72 : 80, resultStride = mode === 0 ? 88 : 80;
  if (w.getUint32(12, true) !== 0 || count > Math.floor((request.length - 16) / stride)) throw new Error("invalid vector resource count");
  let payload = 16 + count * stride, last = -1;
  // Validate all facts before emitting any result, including facts beyond an
  // eventual capacity failure. Payloads have one exact contiguous membership.
  for (let i = 0; i < count; i++) {
    const at = 16 + i * stride, index = w.getUint32(at, true);
    if (index <= last || w.getUint32(at + 4, true) > 1) throw new Error("invalid vector resource source");
    last = index;
    if (mode === 0) {
      if (w.getUint32(at + 8, true) > 1 || w.getUint32(at + 12, true) !== 0 || (w.getUint32(at + 8, true) === 0 && (w.getUint32(at + 16, true) !== 0 || w.getUint32(at + 20, true) !== 0))) throw new Error("invalid vector resource identity");
      const elements = w.getUint32(at + 68, true);
      if (elements > Math.floor((request.length - payload) / 28)) throw new Error("invalid vector elements");
      for (let j = 0; j < elements; j++) if (w.getUint32(payload + j * 28, true) > 4) throw new Error("invalid vector verb");
      payload += elements * 28;
    }
  }
  if (payload !== request.length) throw new Error("invalid vector resource storage");
  const output = new Uint8Array(16 + Math.min(count, capacity) * resultStride), out = new DataView(output.buffer);
  let written = 0, failed = false; payload = 16 + count * stride;
  const f = Math.fround;
  for (let i = 0; i < count; i++) {
    const at = 16 + i * stride, kind = w.getUint32(at + 4, true), hash = new NscVectorHash();
    if (mode === 0) {
      const elements = w.getUint32(at + 68, true), start = payload; payload += elements * 28;
      let width = 0;
      if (kind === 1) {
        const a = w.getFloat32(at + 40, true), b = w.getFloat32(at + 44, true), c = w.getFloat32(at + 48, true), d = w.getFloat32(at + 52, true);
        const x = f(Math.sqrt(f(f(a * a) + f(b * b)))), y = f(Math.sqrt(f(f(c * c) + f(d * d))));
        width = f(nscvVectorNonNegative(w.getFloat32(at + 64, true), false) * nscvVectorMax(f(0.0001), nscvVectorMax(x, y, rules), rules));
        if (width <= 0) continue;
      }
      let contours = 0, lines = 0, quads = 0, cubics = 0, segments = 0, vertices = 0, current = false;
      for (let j = 0; j < elements; j++) {
        const verb = w.getUint32(start + j * 28, true);
        if (verb === 0) { contours++; vertices++; current = true; }
        else if (verb === 1) { if (!current) { contours++; vertices++; current = true; } else { lines++; segments++; vertices++; } }
        else if (verb === 2 && current) { quads++; segments += 12; vertices += 12; }
        else if (verb === 3 && current) { cubics++; segments += 12; vertices += 12; }
        else if (verb === 4 && current) { lines++; segments++; }
      }
      const indices = kind === 0 ? vertices >= 3 ? (vertices - 2) * 3 : 0 : segments * 6;
      if (kind === 1) vertices = segments * 4;
      if (vertices === 0 || indices === 0) continue;
      if (vertices > 4294967295 || indices > 4294967295) throw new Error("vector geometry counts overflow");
      if (written >= capacity) { failed = true; break; }
      const dest = 16 + written * resultStride; output.set(request.subarray(at, at + 40), dest);
      out.setUint32(dest + 40, elements, true); out.setUint32(dest + 44, contours, true); out.setUint32(dest + 48, lines, true); out.setUint32(dest + 52, quads, true); out.setUint32(dest + 56, cubics, true); out.setUint32(dest + 60, segments, true); out.setUint32(dest + 64, vertices, true); out.setUint32(dest + 68, indices, true); out.setFloat32(dest + 72, width, true);
      hash.tag("path_geometry"); hash.tag(kind === 0 ? "fill" : "stroke"); hash.byte(w.getUint32(at + 8, true)); if (w.getUint32(at + 8, true) !== 0) hash.bytes(request, at + 16, 8);
      hash.bytes(request, at + 40, 24); hash.tag("path"); hash.size(elements);
      for (let j = 0; j < elements; j++) { hash.size(w.getUint32(start + j * 28, true)); hash.bytes(request, start + j * 28 + 4, 24); }
      hash.float(width); hash.write(out, dest + 80);
    } else {
      if (written >= capacity) { failed = true; break; }
      const dest = 16 + written * resultStride;
      output.set(request.subarray(at, at + 64), dest);
      let x = w.getFloat32(at + 16, true), y = w.getFloat32(at + 20, true), width = w.getFloat32(at + 24, true), height = w.getFloat32(at + 28, true);
      if (width < 0) { x = f(x + width); width = -width; } if (height < 0) { y = f(y + height); height = -height; }
      const blur = nscvVectorNonNegative(w.getFloat32(at + 56, true), kind === 0 && (rules & 16) !== 0);
      const margin = kind === 0 ? f(nscvVectorNonNegative(Math.abs(w.getFloat32(at + 60, true)), false) + blur) : blur;
      if (kind === 0) { x = f(x + w.getFloat32(at + 48, true)); y = f(y + w.getFloat32(at + 52, true)); }
      out.setFloat32(dest + 16, f(x - margin), true); out.setFloat32(dest + 20, f(y - margin), true); out.setFloat32(dest + 24, f(f(width + margin) + margin), true); out.setFloat32(dest + 28, f(f(height + margin) + margin), true); out.setFloat32(dest + 56, blur, true);
      hash.tag(kind === 0 ? "shadow" : "blur"); hash.bytes(request, at + 16, 16);
      if (kind === 0) { hash.bytes(request, at + 32, 32); hash.bytes(request, at + 64, 16); }
      else { hash.bytes(request, at + 56, 4); output.fill(0, dest + 32, dest + 56); output.fill(0, dest + 60, dest + 64); }
      hash.write(out, dest + 64);
    }
    written++;
  }
  out.setUint32(0, written, true); out.setUint32(4, failed ? 1 : 0, true);
  return output.slice(0, 16 + written * resultStride);
}

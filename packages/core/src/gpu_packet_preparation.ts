/** Retained GPU packet identities and edits over complete copied facts.
 * Hashes use two exact u32 words; native keeps storage and packet encoding. */
class NscPacketReader {
  readonly input: Uint8Array;
  readonly wire: DataView;
  at: number = 32;
  end: number = 32;
  constructor(input: Uint8Array) { this.input = input; this.wire = new DataView(input.buffer, input.byteOffset, input.byteLength); }
  take(length: number): number {
    const at = this.at;
    if (length < 0 || length > this.end - at) throw new Error("invalid packet fact extent");
    this.at += length; return at;
  }
  word(): number { return this.wire.getUint32(this.take(4), true); }
  tag(limit: number): number { const value = this.word(); if (value > limit) throw new Error("invalid packet fact tag"); return value; }
  raw(hash: NscResourceHash, length: number): void { hash.bytes(this.input, this.take(length), length); }
  optional(hash: NscResourceHash, size: number): void { const present = this.tag(1); hash.byte(present); if (present !== 0) this.raw(hash, size); }
  fingerprint(): { packet_id_at: number; packet_index_at: number; packet_fingerprint: NscResourceHash } {
    const hash = new NscResourceHash(); hash.tag("gpu-packet-command");
    const kind = this.tag(14), cap = this.tag(1), index = this.take(8), present = this.tag(1);
    const id = present === 1 ? this.take(8) : -1;
    hash.byte(kind === 14 ? 255 : kind); this.raw(hash, 24); hash.size(cap);
    hash.byte(present); if (id >= 0) hash.bytes(this.input, id, 8);
    this.optional(hash, 16); this.raw(hash, 24);
    const shape = this.tag(5); hash.byte(shape);
    if (shape >= 1 && shape <= 4) this.raw(hash, shape === 1 ? 16 : shape === 2 ? 32 : shape === 3 ? 36 : 20);
    if (shape === 5) {
      const count = this.word(); hash.tag("path"); hash.size(count);
      if (count > Math.floor((this.end - this.at) / 28)) throw new Error("invalid packet path count");
      for (let i = 0; i < count; i++) { hash.size(this.tag(4)); this.raw(hash, 24); }
    }
    const paint = this.tag(2); hash.byte(paint);
    if (paint === 1) this.raw(hash, 16);
    if (paint === 2) {
      this.raw(hash, 16); const stops = this.word(); hash.size(stops);
      if (stops > Math.floor((this.end - this.at) / 20)) throw new Error("invalid packet gradient count");
      this.raw(hash, stops * 20);
    }
    const image = this.tag(1); hash.byte(image);
    if (image === 1) {
      this.raw(hash, 8); this.optional(hash, 16); this.raw(hash, 20);
      hash.size(this.tag(2)); hash.size(this.tag(1)); this.raw(hash, 16);
    }
    const text = this.tag(1); hash.byte(text);
    if (text === 1) {
      this.raw(hash, 36); const length = this.word(); this.raw(hash, length);
      const glyphs = this.word(); hash.size(glyphs);
      if (glyphs > Math.floor((this.end - this.at) / 40)) throw new Error("invalid packet glyph count");
      for (let i = 0; i < glyphs; i++) this.raw(hash, 40);
      const layout = this.tag(1); hash.byte(layout);
      if (layout === 1) {
        for (let i = 0; i < 2; i++) {
          const at = this.take(4);
          if (this.wire.getFloat32(at, true) < 0) hash.word(0); else hash.bytes(this.input, at, 4);
        }
        hash.size(this.tag(2)); hash.size(this.tag(2));
        const overflow = this.tag(1);
        if (overflow !== 0) { hash.tag("text_overflow"); hash.size(overflow); }
      }
    }
    const effect = this.tag(2); hash.byte(effect);
    if (effect !== 0) this.raw(hash, effect === 1 ? 64 : 20);
    if (this.at !== this.end) throw new Error("incomplete packet fact membership");
    return { packet_id_at: id, packet_index_at: index, packet_fingerprint: hash };
  }
}
interface NscPacketKey { packet_key_low: number; packet_key_high: number; packet_slot: number }
function nscvPacketKeyOrder(a: NscPacketKey, b: NscPacketKey): number {
  return a.packet_key_high === b.packet_key_high ? a.packet_key_low - b.packet_key_low : a.packet_key_high - b.packet_key_high;
}
function nscvPacketKeys(wire: DataView, start: number, count: number, stride: number): NscPacketKey[] {
  const keys: NscPacketKey[] = [];
  for (let i = 0; i < count; i++) keys.push({ packet_key_low: wire.getUint32(start + i * stride, true), packet_key_high: wire.getUint32(start + i * stride + 4, true), packet_slot: i });
  keys.sort(nscvPacketKeyOrder); return keys;
}
function nscvGpuPacketPreparation(request: Uint8Array): Uint8Array {
  if (request.length < 32 || request[0] !== 71 || request[1] !== 1 || request[2]! > 1 || request[3] !== 0)
    throw new Error("invalid packet preparation header");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const count = wire.getUint32(4, true), baseline = wire.getUint32(8, true), unique = wire.getUint32(12, true);
  for (let at = 16; at < 32; at += 4) if (wire.getUint32(at, true) !== 0) throw new Error("invalid packet preparation reserved word");
  if (request[2] === 1) return nscvPacketEdits(request, wire, count, baseline, unique);
  if (baseline !== 0 || unique > 1 || count > Math.floor((request.length - 32) / 4)) throw new Error("invalid packet identity counts");
  const output = new Uint8Array(32 + count * 16), out = new DataView(output.buffer);
  out.setUint32(0, 1, true); out.setUint32(4, count, true);
  const reader = new NscPacketReader(request); let end = 32;
  for (let i = 0; i < count; i++) {
    if (end > request.length - 4) throw new Error("missing packet fact extent");
    const length = wire.getUint32(end, true); reader.at = end + 4; reader.end = reader.at + length;
    if (reader.end > request.length) throw new Error("packet fact extent exceeds request");
    const result = reader.fingerprint(); result.packet_fingerprint.write(out, 32 + i * 16 + 8);
    if (result.packet_id_at >= 0) output.set(request.subarray(result.packet_id_at, result.packet_id_at + 8), 32 + i * 16);
    else {
      const key = new NscResourceHash(); key.tag("gpu-packet-synthetic-key");
      key.bytes(request, result.packet_index_at, 8); key.pair(result.packet_fingerprint); key.write(out, 32 + i * 16);
    }
    end = reader.end;
  }
  if (end !== request.length) throw new Error("unclaimed packet preparation bytes");
  if (unique !== 0) {
    const keys = nscvPacketKeys(out, 32, count, 16);
    for (let i = 1; i < keys.length; i++) if (nscvPacketKeyOrder(keys[i - 1]!, keys[i]!) === 0) { out.setUint32(8, 1, true); break; }
  }
  return output;
}
function nscvPacketEdits(request: Uint8Array, wire: DataView, count: number, baseline: number, unique: number): Uint8Array {
  if (unique !== 0 || count > Math.floor((request.length - 32) / 16) || baseline > Math.floor((request.length - 32) / 16) - count || request.length !== 32 + (count + baseline) * 16)
    throw new Error("invalid packet edit counts");
  const output = new Uint8Array(32 + count + baseline), out = new DataView(output.buffer);
  out.setUint32(0, 1, true); out.setUint32(4, count, true); out.setUint32(8, baseline, true);
  const baseAt = 32 + count * 16, sorted = nscvPacketKeys(wire, baseAt, baseline, 16);
  for (let i = 1; i < sorted.length; i++) if (nscvPacketKeyOrder(sorted[i - 1]!, sorted[i]!) === 0) throw new Error("duplicate packet baseline key");
  let upserts = 0, evictions = baseline;
  for (let i = 0; i < count; i++) {
    const at = 32 + i * 16, low = wire.getUint32(at, true), high = wire.getUint32(at + 4, true);
    let first = 0, last = baseline, match = -1;
    while (first < last) {
      const mid = first + Math.floor((last - first) / 2), entry = sorted[mid]!;
      if (entry.packet_key_low === low && entry.packet_key_high === high) { match = entry.packet_slot; break; }
      if (entry.packet_key_high < high || entry.packet_key_high === high && entry.packet_key_low < low) first = mid + 1; else last = mid;
    }
    let changed = true;
    if (match >= 0) {
      if (output[32 + count + match] === 0) { output[32 + count + match] = 1; evictions--; }
      changed = wire.getUint32(at + 8, true) !== wire.getUint32(baseAt + match * 16 + 8, true) || wire.getUint32(at + 12, true) !== wire.getUint32(baseAt + match * 16 + 12, true);
    }
    output[32 + i] = changed ? 1 : 0; if (changed) upserts++;
  }
  out.setUint32(12, upserts, true); out.setUint32(16, evictions, true); return output;
}

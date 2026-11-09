// Complete image, layer and resource plans. Native owns command/pixel storage
// and text capabilities; all identities, hashes, grouping and prefixes are copied.
class NscResourceHash {
  resource_hash_enabled: boolean = true;
  resource_hash_low: number = 0x84222325;
  resource_hash_high: number = 0xcbf29ce4;
  byte(value: number): void {
    if (!this.resource_hash_enabled) return;
    const low = (this.resource_hash_low ^ value) >>> 0, product = low * 435;
    this.resource_hash_high = (this.resource_hash_high * 435 + low * 256 + Math.floor(product / 4294967296)) >>> 0;
    this.resource_hash_low = product >>> 0;
  }
  bytes(input: Uint8Array, start: number, length: number): void { if (!this.resource_hash_enabled) return; for (let i = 0; i < length; i++) this.byte(input[start + i]!); }
  tag(value: string): void { if (!this.resource_hash_enabled) return; const bytes = new TextEncoder().encode(value); this.bytes(bytes, 0, bytes.length); }
  word(value: number): void { if (!this.resource_hash_enabled) return; for (let i = 0; i < 4; i++) this.byte((value >>> (i * 8)) & 255); }
  size(value: number): void { this.word(value); this.word(0); }
  float(value: number): void { if (!this.resource_hash_enabled) return; const bytes = new Uint8Array(4); new DataView(bytes.buffer).setFloat32(0, value, true); this.bytes(bytes, 0, 4); }
  pair(value: NscResourceHash): void { this.word(value.resource_hash_low); this.word(value.resource_hash_high); }
  write(out: DataView, at: number): void { out.setUint32(at, this.resource_hash_low, true); out.setUint32(at + 4, this.resource_hash_high, true); }
}
interface NscResourceRect { x: number; y: number; width: number; height: number }
function nscvResourceRect(w: DataView, at: number): NscResourceRect { return { x: w.getFloat32(at, true), y: w.getFloat32(at + 4, true), width: w.getFloat32(at + 8, true), height: w.getFloat32(at + 12, true) }; }
function nscvResourcePutRect(w: DataView, at: number, r: NscResourceRect): void { w.setFloat32(at, r.x, true); w.setFloat32(at + 4, r.y, true); w.setFloat32(at + 8, r.width, true); w.setFloat32(at + 12, r.height, true); }
function nscvResourceNormalize(r: NscResourceRect): NscResourceRect {
  const f = Math.fround;
  return { x: r.width < 0 ? f(r.x + r.width) : r.x, y: r.height < 0 ? f(r.y + r.height) : r.y, width: r.width < 0 ? -r.width : r.width, height: r.height < 0 ? -r.height : r.height };
}
function nscvResourceExtremum(a: number, b: number, maximum: boolean, rules: number): number {
  if (a === 0 && b === 0 && (1 / a < 0) !== (1 / b < 0)) return (rules & (maximum ? 1 / a < 0 ? 4 : 8 : 1 / a < 0 ? 1 : 2)) !== 0 ? -0 : 0;
  return Number.isNaN(a) ? b : Number.isNaN(b) ? a : (maximum ? a > b : a < b) ? a : b;
}
function nscvResourceUnion(a: NscResourceRect, b: NscResourceRect, rules: number): NscResourceRect {
  const emptyA = a.width <= 0 || a.height <= 0, emptyB = b.width <= 0 || b.height <= 0;
  if (emptyA && emptyB) return { x: 0, y: 0, width: 0, height: 0 };
  if (emptyA) return b; if (emptyB) return a;
  const f = Math.fround, x = nscvResourceExtremum(a.x, b.x, false, rules), y = nscvResourceExtremum(a.y, b.y, false, rules);
  return { x, y, width: f(nscvResourceExtremum(f(a.x + a.width), f(b.x + b.width), true, rules) - x), height: f(nscvResourceExtremum(f(a.y + a.height), f(b.y + b.height), true, rules) - y) };
}
function nscvResourceBytesEqual(a: Uint8Array, x: number, b: Uint8Array, y: number, length: number): boolean { for (let i = 0; i < length; i++) if (a[x + i] !== b[y + i]) return false; return true; }
function nscvResourceFloatsEqual(a: DataView, x: number, b: DataView, y: number, count: number): boolean { for (let i = 0; i < count; i++) if (a.getFloat32(x + i * 4, true) !== b.getFloat32(y + i * 4, true)) return false; return true; }

// One reader validates exact payload membership, then hashes the raw source
// fields. Source hashes never receive native-precomputed resource identities.
class NscResourceSource {
  hashing: boolean = true;
  readonly input: Uint8Array;
  readonly w: DataView;
  readonly rules: number;
  position: number = 0;
  end: number = 0;
  resource_kind: number = -1;
  stops: number = 0;
  glyphs: number = 0;
  text_length: number = 0;
  fill_at: number = 0;
  path_at: number = 0;
  image_at: number = 0;
  font_at: number = 0;
  source_hash: NscResourceHash = new NscResourceHash();
  bounds: NscResourceRect | null = null;
  constructor(input: Uint8Array, rules: number) { this.input = input; this.w = new DataView(input.buffer, input.byteOffset, input.byteLength); this.rules = rules; }
  newHash(): NscResourceHash { const hash = new NscResourceHash(); hash.resource_hash_enabled = this.hashing; return hash; }
  take(length: number): number { const at = this.position; if (length < 0 || length > this.end - at) throw new Error("invalid resource payload"); this.position += length; return at; }
  word(): number { return this.w.getUint32(this.take(4), true); }
  raw(hash: NscResourceHash, length: number): void { hash.bytes(this.input, this.take(length), length); }
  rect(): NscResourceRect { return nscvResourceRect(this.w, this.take(16)); }
  path(hash: NscResourceHash): void {
    const count = this.word(); this.path_at = this.position; hash.tag("path"); hash.size(count);
    for (let i = 0; i < count; i++) { const verb = this.word(); if (verb > 4) throw new Error("invalid resource path verb"); hash.size(verb); this.raw(hash, 24); }
  }
  fill(hash: NscResourceHash): void {
    const tag = this.word(); this.fill_at = this.position;
    if (tag === 0) { hash.tag("color"); this.raw(hash, 16); }
    else if (tag === 1) {
      const gradient = this.newHash(); gradient.tag("linear_gradient"); this.raw(gradient, 16); this.stops = this.word(); gradient.size(this.stops);
      this.raw(gradient, this.stops * 20); hash.tag("linear_gradient"); hash.pair(gradient); this.resource_kind = 0; this.source_hash = gradient;
    } else throw new Error("invalid resource fill");
  }
  stroke(hash: NscResourceHash): number { hash.tag("stroke"); const at = this.take(4); hash.bytes(this.input, at, 4); this.fill(hash); return this.w.getFloat32(at, true); }
  pathBounds(count: number): NscResourceRect | null {
    let found = false, x = 0, y = 0, right = 0, bottom = 0; const f = Math.fround;
    for (let i = 0; i < count; i++) {
      const at = this.path_at + i * 28, verb = this.w.getUint32(at, true), points = verb < 2 ? 1 : verb === 2 ? 2 : verb === 3 ? 3 : 0;
      for (let j = 0; j < points; j++) {
        const px = this.w.getFloat32(at + 4 + j * 8, true), py = this.w.getFloat32(at + 8 + j * 8, true);
        if (!found) { x = right = px; y = bottom = py; found = true; }
        else { x = nscvResourceExtremum(x, px, false, this.rules); y = nscvResourceExtremum(y, py, false, this.rules); right = nscvResourceExtremum(right, px, true, this.rules); bottom = nscvResourceExtremum(bottom, py, true, this.rules); }
      }
    }
    return found ? { x, y, width: f(right - x), height: f(bottom - y) } : null;
  }
  inflate(r: NscResourceRect, margin: number): NscResourceRect { const f = Math.fround; return { x: f(r.x - margin), y: f(r.y - margin), width: f(f(r.width + margin) + margin), height: f(f(r.height + margin) + margin) }; }
  read(at: number): NscResourceHash {
    const w = this.w, kind = w.getUint32(at + 4, true), start = w.getUint32(at + 112, true), length = w.getUint32(at + 116, true);
    this.position = start; this.end = start + length; this.resource_kind = -1; this.stops = this.glyphs = this.text_length = 0; this.bounds = null; this.image_at = this.font_at = 0;
    const hash = this.newHash(); hash.tag("render_command"); hash.byte(w.getUint32(at + 16, true)); if (w.getUint32(at + 16, true) !== 0) hash.bytes(this.input, at + 24, 8); hash.bytes(this.input, at + 32, 32);
    const tags = ["push_clip", "pop_clip", "push_opacity", "pop_opacity", "transform", "fill_rect", "stroke_rect", "fill_rounded_rect", "draw_line", "fill_path", "stroke_path", "draw_image", "draw_text", "shadow", "blur"];
    if (kind > 14) throw new Error("invalid resource command kind"); hash.tag(tags[kind]!);
    if (kind !== 1 && kind !== 2 && kind !== 3 && kind !== 4) { const present = w.getUint32(at + 8, true) !== 0 || w.getUint32(at + 12, true) !== 0; hash.byte(present ? 1 : 0); if (present) hash.bytes(this.input, at + 8, 8); }
    const f = Math.fround;
    if (kind === 0) this.raw(hash, 32);
    else if (kind === 5 || kind === 6 || kind === 7 || kind === 8) {
      const rawAt = this.take(16); hash.bytes(this.input, rawAt, 16);
      let bounds = nscvResourceNormalize(nscvResourceRect(w, rawAt));
      if (kind === 8) { const ax = w.getFloat32(rawAt, true), ay = w.getFloat32(rawAt + 4, true), bx = w.getFloat32(rawAt + 8, true), by = w.getFloat32(rawAt + 12, true), x = nscvResourceExtremum(ax, bx, false, this.rules), y = nscvResourceExtremum(ay, by, false, this.rules); bounds = { x, y, width: f(nscvResourceExtremum(ax, bx, true, this.rules) - x), height: f(nscvResourceExtremum(ay, by, true, this.rules) - y) }; }
      if (kind === 6 || kind === 7) this.raw(hash, 16);
      if (kind === 6 || kind === 8) { const width = this.stroke(hash); bounds = this.inflate(bounds, f((width > 0 ? width : 0) * 0.5)); }
      else this.fill(hash);
      this.bounds = bounds;
    } else if (kind === 9 || kind === 10) {
      const countAt = this.position; this.path(hash); let bounds = this.pathBounds(w.getUint32(countAt, true));
      if (kind === 10) { const width = this.stroke(hash); if (bounds !== null) bounds = this.inflate(nscvResourceNormalize(bounds), f((width > 0 ? width : 0) * 0.5)); const cap = this.word(); if (cap > 2) throw new Error("invalid resource stroke cap"); hash.size(cap); }
      else this.fill(hash); this.bounds = bounds;
    } else if (kind === 11) {
      this.resource_kind = 1; this.image_at = this.position; const image = this.newHash(); image.tag("image"); this.raw(image, 8);
      const src = this.word(); if (src > 1) throw new Error("invalid resource image source"); image.byte(src); const source = this.take(16); if (src !== 0) image.bytes(this.input, source, 16);
      const fit = this.word(), sampling = this.word(); if (fit > 2 || sampling > 1) throw new Error("invalid resource image enum"); image.size(fit); image.size(sampling); hash.pair(image); this.source_hash = image;
      const dst = this.take(16); hash.bytes(this.input, dst, 16); this.bounds = nscvResourceNormalize(nscvResourceRect(w, dst)); this.raw(hash, 20);
    } else if (kind === 12) {
      this.resource_kind = 2; this.font_at = this.position; const text = this.newHash(); text.tag("glyph_run"); this.raw(text, 20);
      this.text_length = this.word(); this.raw(text, this.text_length); this.glyphs = this.word(); text.size(this.glyphs);
      for (let i = 0; i < this.glyphs; i++) {
        this.raw(text, 4); const font = this.take(8); text.bytes(this.input, w.getUint32(font, true) !== 0 || w.getUint32(font + 4, true) !== 0 ? font : this.font_at, 8); this.raw(text, 12); text.size(this.word()); text.size(this.word());
      }
      const layout = this.word(); if (layout > 1) throw new Error("invalid resource text layout"); text.byte(layout);
      if (layout !== 0) {
        for (let i = 0; i < 2; i++) { const value = w.getFloat32(this.take(4), true); text.float(value > 0 ? value : 0); }
        const wrap = this.word(), align = this.word(), overflow = this.word(); if (wrap > 2 || align > 2 || overflow > 1) throw new Error("invalid resource text enum"); text.size(wrap); text.size(align); if (overflow !== 0) { text.tag("text_overflow"); text.size(overflow); }
      }
      hash.pair(text); this.source_hash = text; this.raw(hash, 16); this.bounds = w.getUint32(at + 120, true) === 1 ? nscvResourceRect(w, at + 124) : null;
    } else if (kind === 13 || kind === 14) {
      this.resource_kind = kind === 13 ? 3 : 4; const effect = this.newHash(); effect.tag(kind === 13 ? "shadow" : "blur"); effect.bytes(this.input, this.position, length); hash.pair(effect); this.source_hash = effect;
      let bounds = nscvResourceNormalize(this.rect()), margin = 0;
      if (kind === 13) { this.take(16); const dx = w.getFloat32(this.take(4), true), dy = w.getFloat32(this.take(4), true), blur = w.getFloat32(this.take(4), true), spread = w.getFloat32(this.take(4), true); bounds = { x: f(bounds.x + dx), y: f(bounds.y + dy), width: bounds.width, height: bounds.height }; margin = f(Math.abs(spread) + (blur > 0 || blur === 0 && (this.rules & 16) !== 0 ? blur : 0)); this.take(16); }
      else { const radius = w.getFloat32(this.take(4), true); margin = radius > 0 ? radius : 0; }
      this.bounds = this.inflate(bounds, margin);
    }
    if (this.position !== this.end) throw new Error("invalid resource payload membership"); return hash;
  }
}

function nscvRenderResources(request: Uint8Array): Uint8Array {
  if (request.length < 32 || request[0] !== 64 || request[1] !== 1 || request[2]! > 2 || request[3]! > 31) throw new Error("invalid resource header");
  if (request[2] === 0) return nscvImageResources(request);
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), count = w.getUint32(4, true), capacity = w.getUint32(8, true), mode = request[2]!, stride = mode === 1 ? 104 : 80, end = w.getUint32(16, true), resume = w.getUint32(20, true), prefix = w.getUint32(24, true);
  if (w.getUint32(12, true) !== 0 || w.getUint32(28, true) !== 0 || count > Math.floor((request.length - 32) / 144) || end + prefix !== request.length || resume > count || mode === 1 && (prefix !== 0 || resume !== 0)) throw new Error("invalid resource shape");
  const reader = new NscResourceSource(request, request[3]!); reader.hashing = false; let payload = 32 + count * 144, previous = -1;
  for (let i = 0; i < count; i++) {
    const at = 32 + i * 144, index = w.getUint32(at, true), present = w.getUint32(at + 16, true), clip = w.getUint32(at + 68, true), bounds = w.getUint32(at + 120, true), length = w.getUint32(at + 116, true);
    if (index <= previous || present > 1 || clip > 1 || bounds > 2 || w.getUint32(at + 20, true) !== 0 || w.getUint32(at + 140, true) !== 0 || w.getUint32(at + 112, true) !== payload || length > end - payload || present === 0 && (w.getUint32(at + 24, true) !== 0 || w.getUint32(at + 28, true) !== 0) || bounds === 2 && (mode !== 2 || w.getUint32(at + 4, true) !== 12)) throw new Error("invalid resource facts");
    reader.read(at); payload += length; previous = index;
  }
  if (payload !== end) throw new Error("invalid resource storage");
  reader.hashing = true;
  const output = new Uint8Array(32 + Math.min(count, capacity) * stride), out = new DataView(output.buffer); let written = 0;
  if (prefix !== 0) {
    if (prefix < 32 || w.getUint32(end + 4, true) !== 2 || w.getUint32(end + 8, true) !== resume) throw new Error("invalid resource continuation");
    written = w.getUint32(end, true); if (written > capacity || written > resume || prefix !== 32 + written * stride) throw new Error("invalid resource continuation prefix"); output.set(request.subarray(end + 32, end + prefix), 32);
  } else if (resume !== 0) throw new Error("invalid resource resume");
  for (let i = resume; i < count; i++) {
    const at = 32 + i * 144, hash = reader.read(at), kind = w.getUint32(at + 4, true), index = w.getUint32(at, true);
    if (mode === 1) {
      const identity = w.getFloat32(at + 88, true) === 1 && w.getFloat32(at + 100, true) === 1 && w.getFloat32(at + 92, true) === 0 && w.getFloat32(at + 96, true) === 0 && w.getFloat32(at + 104, true) === 0 && w.getFloat32(at + 108, true) === 0;
      if (w.getFloat32(at + 64, true) === 1 && w.getUint32(at + 68, true) === 0 && identity) continue;
      let dest = 32 + written * stride, extend = false;
      if (written > 0) {
        dest -= stride; extend = out.getUint32(dest, true) + out.getUint32(dest + 4, true) === index && out.getFloat32(dest + 40, true) === w.getFloat32(at + 64, true) && out.getUint32(dest + 44, true) === w.getUint32(at + 68, true) && (w.getUint32(at + 68, true) === 0 || nscvResourceFloatsEqual(out, dest + 48, w, at + 72, 4)) && nscvResourceFloatsEqual(out, dest + 64, w, at + 88, 6);
      }
      const layerHash = new NscResourceHash();
      if (extend) {
        out.setUint32(dest + 4, out.getUint32(dest + 4, true) + 1, true);
        if (out.getUint32(dest + 8, true) !== w.getUint32(at + 16, true) || !nscvResourceBytesEqual(output, dest + 16, request, at + 24, 8)) { out.setUint32(dest + 8, 0, true); output.fill(0, dest + 16, dest + 24); }
        nscvResourcePutRect(out, dest + 24, nscvResourceUnion(nscvResourceNormalize(nscvResourceRect(out, dest + 24)), nscvResourceNormalize(nscvResourceRect(w, at + 48)), request[3]!));
        layerHash.resource_hash_low = out.getUint32(dest + 88, true); layerHash.resource_hash_high = out.getUint32(dest + 92, true);
      } else {
        if (written >= capacity) { out.setUint32(4, 1, true); break; }
        dest = 32 + written * stride; out.setUint32(dest, index, true); out.setUint32(dest + 4, 1, true); out.setUint32(dest + 8, w.getUint32(at + 16, true), true); output.set(request.subarray(at + 24, at + 32), dest + 16); output.set(request.subarray(at + 48, at + 112), dest + 24); written++;
        layerHash.tag("layer"); layerHash.bytes(request, at + 64, 4); layerHash.byte(w.getUint32(at + 68, true)); if (w.getUint32(at + 68, true) !== 0) layerHash.bytes(request, at + 72, 16); layerHash.bytes(request, at + 88, 24);
      }
      layerHash.pair(hash); layerHash.write(out, dest + 88);
    } else {
      if (reader.resource_kind < 0) continue;
      if (kind === 12 && w.getUint32(at + 120, true) === 2) { out.setUint32(4, 2, true); out.setUint32(8, i, true); break; }
      if (written >= capacity) { out.setUint32(4, 1, true); break; }
      const dest = 32 + written * stride; out.setUint32(dest, reader.resource_kind, true); out.setUint32(dest + 4, index, true);
      const present = w.getUint32(at + 8, true) !== 0 || w.getUint32(at + 12, true) !== 0; out.setUint32(dest + 8, present ? 1 : 0, true); if (present) output.set(request.subarray(at + 8, at + 16), dest + 16);
      if (reader.bounds !== null) { out.setUint32(dest + 12, 1, true); nscvResourcePutRect(out, dest + 24, reader.bounds); }
      if (reader.image_at !== 0) output.set(request.subarray(reader.image_at, reader.image_at + 8), dest + 40); if (reader.font_at !== 0) output.set(request.subarray(reader.font_at, reader.font_at + 8), dest + 48);
      out.setUint32(dest + 56, reader.stops, true); out.setUint32(dest + 60, reader.glyphs, true); out.setUint32(dest + 64, reader.text_length, true); reader.source_hash.write(out, dest + 72); written++;
    }
  }
  out.setUint32(0, written, true); return output.slice(0, 32 + written * stride);
}

// Pixel windows are explicit storage reads. The compiled owner selects the
// first matching resource and streams the complete raw bytes into its own hash.
function nscvImageResources(request: Uint8Array): Uint8Array {
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), count = w.getUint32(4, true), capacity = w.getUint32(8, true), resources = w.getUint32(12, true), end = w.getUint32(16, true), resume = w.getUint32(20, true), prefix = w.getUint32(24, true), chunk = w.getUint32(28, true);
  const refs = 32 + count * 48;
  if (count > Math.floor((request.length - 32) / 48) || resources > Math.floor((request.length - refs) / 48) || end !== refs + resources * 48 || end + prefix + chunk !== request.length || resume > count || chunk > 65536) throw new Error("invalid image resource shape");
  let previous = -1;
  for (let i = 0; i < count; i++) { const at = 32 + i * 48, index = w.getUint32(at, true), present = w.getUint32(at + 4, true); if (index <= previous || present > 1 || w.getUint32(at + 40, true) !== 0 || w.getUint32(at + 44, true) !== 0 || present === 0 && (w.getUint32(at + 8, true) !== 0 || w.getUint32(at + 12, true) !== 0)) throw new Error("invalid image draw facts"); previous = index; }
  for (let i = 0; i < resources; i++) { const at = refs + i * 48; if (w.getUint32(at + 36, true) !== 0 || w.getUint32(at + 40, true) !== 0 || w.getUint32(at + 44, true) !== 0) throw new Error("invalid image storage facts"); }
  const output = new Uint8Array(32 + Math.min(count, capacity) * 80), out = new DataView(output.buffer); let written = 0;
  if (prefix !== 0) { if (prefix < 32 || w.getUint32(end + 4, true) !== 2 || w.getUint32(end + 8, true) !== resume) throw new Error("invalid image continuation"); written = w.getUint32(end, true); if (written > capacity || written > resume || prefix !== 32 + written * 80) throw new Error("invalid image prefix"); output.set(request.subarray(end + 32, end + prefix), 32); }
  else if (resume !== 0 || chunk !== 0) throw new Error("invalid image resume");
  for (let i = resume; i < count; i++) {
    const at = 32 + i * 48; let resource = -1;
    for (let j = 0; j < resources; j++) if (nscvResourceBytesEqual(request, at + 16, request, refs + j * 48, 8)) { resource = j; break; }
    const hash = new NscResourceHash(); hash.tag("image_texture"); hash.bytes(request, at + 16, 8); let offset = 0;
    if (resource >= 0) {
      const r = refs + resource * 48; hash.bytes(request, r + 8, 16);
      const stamped = w.getUint32(r + 24, true) !== 0 || w.getUint32(r + 28, true) !== 0, pixels = w.getUint32(r + 32, true);
      if (stamped) hash.bytes(request, r + 24, 8);
      else {
        if (i === resume && prefix !== 0) { if (w.getUint32(end + 12, true) !== resource) throw new Error("invalid image window resource"); offset = w.getUint32(end + 16, true); if (offset >= pixels || chunk === 0 || chunk > pixels - offset) throw new Error("invalid image window range"); hash.resource_hash_low = w.getUint32(end + 20, true); hash.resource_hash_high = w.getUint32(end + 24, true); hash.bytes(request, end + prefix, chunk); offset += chunk; }
        if (offset < pixels) { out.setUint32(0, written, true); out.setUint32(4, 2, true); out.setUint32(8, i, true); out.setUint32(12, resource, true); out.setUint32(16, offset, true); hash.write(out, 20); return output.slice(0, 32 + written * 80); }
      }
    } else if (i === resume && prefix !== 0) throw new Error("invalid image missing window");
    let existing = -1;
    for (let j = 0; j < written; j++) { const dest = 32 + j * 80; if (nscvResourceBytesEqual(output, dest, request, at + 16, 8) && out.getUint32(dest + 68, true) === hash.resource_hash_low && out.getUint32(dest + 72, true) === hash.resource_hash_high) { existing = dest; break; } }
    if (existing >= 0) {
      out.setUint32(existing + 24, out.getUint32(existing + 24, true) + 1, true);
      if (out.getUint32(existing + 12, true) !== w.getUint32(at + 4, true) || !nscvResourceBytesEqual(output, existing + 16, request, at + 8, 8)) { out.setUint32(existing + 12, 0, true); output.fill(0, existing + 16, existing + 24); }
      nscvResourcePutRect(out, existing + 52, nscvResourceUnion(nscvResourceNormalize(nscvResourceRect(out, existing + 52)), nscvResourceNormalize(nscvResourceRect(w, at + 24)), request[3]!));
    } else {
      if (written >= capacity) { out.setUint32(4, 1, true); break; }
      const dest = 32 + written * 80; output.set(request.subarray(at + 16, at + 24), dest); out.setUint32(dest + 8, w.getUint32(at, true), true); out.setUint32(dest + 12, w.getUint32(at + 4, true), true); output.set(request.subarray(at + 8, at + 16), dest + 16); out.setUint32(dest + 24, 1, true);
      if (resource >= 0) { output.set(request.subarray(refs + resource * 48 + 8, refs + resource * 48 + 24), dest + 32); }
      out.setUint32(dest + 48, resource < 0 ? 0xffffffff : resource, true); output.set(request.subarray(at + 24, at + 40), dest + 52); hash.write(out, dest + 68); written++;
    }
  }
  out.setUint32(0, written, true); return output.slice(0, 32 + written * 80);
}

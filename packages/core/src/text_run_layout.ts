// Scalar helpers need no continuation receiver or captured state.
function nscvTextRunAdd(a: number, b: number): number { return Math.fround(a + b); }
function nscvTextRunSubtract(a: number, b: number): number { return Math.fround(a - b); }
function nscvTextRunMultiply(a: number, b: number): number { return Math.fround(a * b); }
function nscvTextRunDivide(a: number, b: number): number { return Math.fround(a / b); }
function nscvTextRunMin(a: number, b: number): number { return nscvShellMin(a, b); }
function nscvTextRunMax(a: number, b: number): number { return nscvShellMax(a, b); }
function nscvTextRunSequenceLength(byte: number): number { return (byte & 128) === 0 ? 1 : (byte & 224) === 192 ? 2 : (byte & 240) === 224 ? 3 : (byte & 248) === 240 ? 4 : 1; }

// Ordinary text planning uses copied continuations. Fonts, widths and
// advances are capabilities; cursor, overflow and geometry decisions are
// portable. No result borrows a compiler frame or a host pointer.
function nscvTextRunLayout(request: Uint8Array): Uint8Array {
  return new NscTextRunContext(request).run();
}

// One context owns each copied continuation; methods do not allocate captured
// helper closures when a font capability resumes the planner.
class NscTextRunContext {
  readonly out: Uint8Array;
  readonly w: DataView;
  readonly facts: DataView;
  readonly mode: number;
  readonly size: number;
  readonly ox: number;
  readonly oy: number;
  readonly width: number;
  readonly textLength: number;
  readonly glyphCount: number;
  readonly advancesAt: number;
  readonly textAt: number;
  readonly text: Uint8Array;
  readonly hasMeasure: boolean;
  readonly drawMeasure: boolean;
  phase: number;
  private wholeScalarCount = -1;

  constructor(request: Uint8Array) {
    if (request.length < 512 || request[0] !== 54 || request[1] !== 1 || request[2]! > 8 || request[3]! > 1 || request[4]! > 2 || request[5]! > 2 || request[6]! > 1 || request[7]! > 3)
      throw new Error("invalid text run header");
    const out = request.slice(0, 512);
    this.out = out;
    this.w = new DataView(out.buffer);
    this.facts = new DataView(request.buffer, request.byteOffset, request.byteLength);
    this.mode = out[2]!;
    this.size = this.f(16);
    this.ox = this.f(20);
    this.oy = this.f(24);
    this.width = this.f(28);
    this.textLength = this.u(36);
    this.glyphCount = this.u(40);
    this.advancesAt = 512 + this.glyphCount * 32;
    this.textAt = this.advancesAt + this.textLength * 4;
    if (this.u(8) !== this.textAt || this.u(12) !== request.length || this.textAt + this.textLength !== request.length || this.u(52) > 1 || this.u(44) > (this.glyphCount > 0 && this.mode === 0 ? this.glyphCount : this.textLength))
      throw new Error("invalid text run storage");
    this.text = request.subarray(this.textAt);
    this.hasMeasure = (out[7]! & 1) !== 0;
    this.drawMeasure = (out[7]! & 2) !== 0;
    for (let n = 0; n < this.glyphCount; n++) for (let at = 512 + n * 32 + 20; at < 512 + (n + 1) * 32; at++) if (request[at] !== 0) throw new Error("invalid text glyph reserved byte");
    if (this.u(356) > 1 || this.u(364) > 1) throw new Error("invalid text line flags");
    for (let at = 376; at < 512; at++) if (out[at] !== 0) throw new Error("invalid text reserved byte");
    if (out[3] === 0) {
      for (let at = 80; at < 320; at++) if (out[at] !== 0) throw new Error("invalid initial text state");
      if (this.mode === 0 || this.mode === 1) for (let at = 320; at < 376; at++) if (out[at] !== 0) throw new Error("invalid initial text line");
    }
    this.phase = this.u(96);
    if (out[3] === 0 ? this.phase !== 0 : this.u(112) !== 1) throw new Error("invalid text continuation reply");
    if (this.phase !== 0 && (this.u(100) < 1 || this.u(100) > 7 || this.u(104) > this.u(108) || this.u(108) > this.textLength || this.u(120) > 1)) throw new Error("invalid text continuation capability");
    if (this.phase !== 0 && !(this.mode === 0 && (this.phase === 1 || this.phase === 3 || this.phase === 11 || this.phase === 12 || this.phase === 14 || this.phase === 15 || this.phase === 17 || this.phase === 19 || this.phase === 21 || this.phase === 22 || this.phase === 24 || this.phase === 31 || this.phase === 32) || this.mode === 1 && (this.phase === 1 || this.phase === 3) || this.mode === 2 && this.phase === 40 || this.mode === 3 && (this.phase === 42 || this.phase === 43) || this.mode === 4 && (this.phase === 31 || this.phase === 32) || this.mode === 5 && this.phase === 50 || this.mode === 6 && (this.phase === 60 || this.phase === 61) || this.mode === 8 && (this.phase === 50 || this.phase === 62))) throw new Error("invalid text mode continuation");
    if (this.phase !== 0) {
      const kind = this.phase === 1 || this.phase === 12 ? 3 : this.phase === 11 || this.phase === 15 || this.phase === 24 ? 5 : this.phase === 19 || this.phase === 21 ? 2 : this.phase === 31 ? 4 : this.phase === 42 ? this.drawMeasure ? 1 : 2 : this.phase === 60 || this.phase === 62 ? 6 : this.phase === 61 ? 7 : 1;
      if (this.u(100) !== kind || (kind === 3 || kind === 4) && (this.u(104) !== 0 || this.u(108) !== this.textLength) || (kind === 5 || kind === 7) && (this.u(104) !== 0 || this.u(108) !== 0)) throw new Error("invalid text phase capability");
    }
  }

  u(at: number): number { return this.w.getUint32(at, true); }
  f(at: number): number { return (at < 512 ? this.w : this.facts).getFloat32(at, true); }
  put(at: number, value: number): void { this.w.setUint32(at, value, true); }
  float(at: number, value: number): void { this.w.setFloat32(at, value, true); }
  glyph(n: number, field: number): number { if (n >= this.glyphCount) throw new Error("invalid text glyph index"); return this.f(512 + n * 32 + field); }
  glyphWord(n: number, field: number): number { if (n >= this.glyphCount) throw new Error("invalid text glyph index"); return this.facts.getUint32(512 + n * 32 + field, true); }
  advance(n: number): number { return nscvTextRunMax(nscvTextRunMultiply(this.size, 0.25), this.glyph(n, 8)); }
  snap(offset: number): number { let p = Math.min(offset, this.textLength); while (p > 0 && p < this.textLength && (this.text[p]! & 192) === 128) p--; return p; }
  next(offset: number): number { const p = this.snap(offset); if (p >= this.textLength) return this.textLength; const end = Math.min(this.textLength, p + nscvTextRunSequenceLength(this.text[p]!)); return end <= offset ? Math.min(this.textLength, offset + 1) : end; }
  isBreak(p: number): boolean { return this.text[p] === 32 || this.text[p] === 9; }
  scalarCount(a: number, b: number): number { const text = this.text; let n = 0; while (a < b) { n++; a += Math.min(nscvTextRunSequenceLength(text[a]!), b - a); } return n; }
  scalarOffset(a: number, b: number, count: number): number { let n = 0; while (a < b && n < count) { a = Math.min(b, this.next(a)); n++; } return a; }
  // Preserve exact u64 product/division for proportional glyph ranges.
  ratioIndex(a: number, b: number, denominator: number, ceil: boolean): number {
    const al = a % 65536, ah = Math.floor(a / 65536), bl = b % 65536, bh = Math.floor(b / 65536);
    const p0 = al * bl, p1 = ah * bl + al * bh + Math.floor(p0 / 65536);
    const product: NscFlowInteger = { low: p0 % 65536 + (p1 % 65536) * 65536, high: ah * bh + Math.floor(p1 / 65536) };
    const result = nscvSemanticDivide(product, nscvFlowSmall(denominator));
    return result.quotient.low + result.quotient.high * 4294967296 + (ceil && (result.remainder.low !== 0 || result.remainder.high !== 0) ? 1 : 0);
  }
  range(start: number, length: number): { run_first_byte: number; run_last_byte: number } {
    if (this.textLength === 0 || this.glyphCount === 0) return { run_first_byte: 0, run_last_byte: 0 };
    const end = Math.min(this.glyphCount, start + length);
    let a = this.textLength, b = 0, explicit = length > 0 && start < this.glyphCount;
    if (explicit) for (let n = start; n < end; n++) {
      const size = this.glyphWord(n, 16); if (size === 0) { explicit = false; break; }
      const at = this.glyphWord(n, 12), first = this.snap(at), last = this.snap(at + size);
      a = Math.min(a, first); b = Math.max(b, last);
    }
    if (explicit) return { run_first_byte: a, run_last_byte: b };
    // Explicit glyph ranges need no whole-run scan. Proportional fallback
    // counts the immutable source once per copied continuation.
    if (this.wholeScalarCount < 0) this.wholeScalarCount = this.scalarCount(0, this.textLength);
    const count = this.wholeScalarCount;
    if (count === 0) return { run_first_byte: 0, run_last_byte: 0 };
    return { run_first_byte: this.scalarOffset(0, this.textLength, Math.min(count, this.ratioIndex(start, count, this.glyphCount, false))), run_last_byte: this.scalarOffset(0, this.textLength, Math.min(count, this.ratioIndex(end, count, this.glyphCount, true))) };
  }
  glyphBreak(n: number): boolean { const r = this.range(n, 1); return r.run_first_byte < r.run_last_byte && this.isBreak(r.run_first_byte); }
  trim(a: number, b: number): number { let p = b; while (p > a && this.isBreak(p - 1)) p--; return p === a ? b : p; }
  done(): Uint8Array { this.out[3] = 2; this.put(96, 0); this.put(100, 0); this.put(112, 0); return this.out; }
  ask(phase: number, kind: number, a: number, b: number): Uint8Array {
    if (a > b || b > this.textLength) throw new Error("invalid text capability range");
    this.put(96, phase); this.put(100, kind); this.put(104, a); this.put(108, b); this.put(112, 0); this.float(116, 0); this.out[3] = 1; return this.out;
  }
  rawGlyphBounds(start: number, length: number, baseline: number, height: number): void {
    const end = Math.min(this.glyphCount, start + length), firstX = this.glyph(start, 0);
    let minX = 0, maxX = this.advance(start), minY = nscvTextRunSubtract(baseline, this.size), maxY = nscvTextRunAdd(minY, height);
    for (let n = start; n < end; n++) {
      const x = nscvTextRunSubtract(this.glyph(n, 0), firstX), y = this.glyph(n, 4);
      minX = nscvTextRunMin(minX, x); maxX = nscvTextRunMax(maxX, nscvTextRunAdd(x, this.advance(n)));
      minY = nscvTextRunMin(minY, nscvTextRunSubtract(nscvTextRunAdd(baseline, y), this.size)); maxY = nscvTextRunMax(maxY, nscvTextRunAdd(nscvTextRunAdd(baseline, y), nscvTextRunMultiply(this.size, 0.25)));
    }
    this.float(336, nscvTextRunAdd(this.ox, minX)); this.float(340, minY); this.float(344, nscvTextRunMax(0, nscvTextRunSubtract(maxX, minX))); this.float(348, nscvTextRunMax(0, nscvTextRunSubtract(maxY, minY)));
  }
  finishBounds(): Uint8Array {
    if (this.mode === 4) return this.done();
    this.float(344, nscvTextRunAdd(this.f(344), this.f(372)));
    const limit = nscvTextRunMax(0, this.width);
    if (!(limit <= 0 || this.f(344) >= limit)) {
      const extra = nscvTextRunSubtract(limit, this.f(344)), dx = this.out[5] === 0 ? 0 : this.out[5] === 1 ? nscvTextRunMultiply(extra, 0.5) : extra;
      this.float(336, nscvTextRunAdd(this.f(336), dx)); this.float(340, nscvTextRunAdd(this.f(340), 0));
    }
    this.put(300, 1); return this.done();
  }
  setLine(ts: number, tl: number, gs: number, gl: number): void {
    this.put(320, ts); this.put(324, tl); this.put(328, gs); this.put(332, gl);
    const height = this.f(32) > 0 ? this.f(32) : nscvTextRunMultiply(this.size, 1.25), baseline = nscvTextRunAdd(this.oy, nscvTextRunMultiply(Math.fround(this.u(48)), height));
    this.float(352, baseline); this.float(348, height);
  }
  endPlain(end: number): void {
    this.put(148, end);
    if (this.mode === 1) { this.put(308, end); this.phase = 99; return; }
    let cursor = end;
    const finished = end >= this.textLength;
    if (!finished) { if (this.text[cursor] === 10) cursor++; else while (this.out[4] === 1 && cursor < this.textLength && this.isBreak(cursor)) cursor++; }
    this.put(288, finished ? this.u(44) : cursor); this.put(292, this.u(48) + 1); this.put(296, finished ? 1 : 0);
    this.setLine(this.u(144), end - this.u(144), this.u(144), end - this.u(144)); this.phase = 10;
  }
  takeBreakWidth(value: number): void {
    const p = this.u(152), n = this.next(p); if (this.isBreak(p)) { this.put(156, n); this.put(160, 1); }
    const limit = this.width > 0 ? this.width : Infinity;
    if (value > limit) this.endPlain(p === this.u(144) ? n : this.out[4] === 1 && this.u(160) !== 0 && this.u(156) > this.u(144) ? this.trim(this.u(144), this.u(156)) : p);
    else { this.float(164, value); this.put(152, n); this.phase = 2; }
  }
  elided(length: number, painted: number): void { this.put(356, 1); this.put(360, length); this.float(184, painted); this.put(188, 1); this.phase = 30; }
  takeElisionAdvance(value: number): void {
    const p = this.u(152), n = this.next(p), total = nscvTextRunAdd(this.f(164), value); this.float(164, total);
    if (total <= nscvTextRunSubtract(this.width, this.f(372))) { this.put(172, n); this.float(176, total); }
    this.put(152, n); this.phase = 18;
  }
  lineRange(): { run_first_byte: number; run_last_byte: number } { const start = Math.min(this.u(320), this.textLength); return { run_first_byte: start, run_last_byte: Math.min(this.textLength, start + this.u(324)) }; }
  explicitLine(): boolean { if (this.u(332) === 0 || this.u(328) >= this.glyphCount) return false; for (let n = this.u(328); n < Math.min(this.glyphCount, this.u(328) + this.u(332)); n++) if (this.glyphWord(n, 16) === 0) return false; return true; }
  savedRawGlyphBounds(): { dx: number; first: number } {
    const x = this.f(336), bh = this.f(348), saved = this.out.slice(336, 352);
    this.rawGlyphBounds(this.u(328), this.u(332), this.f(352), bh); const rawX = this.f(336);
    this.out.set(saved, 336);
    return { dx: nscvTextRunSubtract(x, rawX), first: this.glyph(this.u(328), 0) };
  }
  glyphX(n: number, first: number, dx: number): number { return nscvTextRunAdd(nscvTextRunSubtract(nscvTextRunAdd(this.ox, this.glyph(n, 0)), first), dx); }
  inflate(): void {
    const em = nscvTextRunMax(0, this.size), left = nscvTextRunMultiply(em, 0.1), top = nscvTextRunMultiply(em, 0.35);
    this.float(336, nscvTextRunSubtract(this.f(336), left)); this.float(340, nscvTextRunSubtract(this.f(340), top));
    this.float(344, nscvTextRunAdd(nscvTextRunAdd(this.f(344), left), top)); this.float(348, nscvTextRunAdd(nscvTextRunAdd(this.f(348), top), left));
  }
  unionInk(x: number, y: number): void {
    if (this.u(120) === 0) return;
    const bx = nscvTextRunAdd(x, this.f(124)), by = nscvTextRunSubtract(y, this.f(136)), bw = nscvTextRunSubtract(this.f(132), this.f(124)), bh = nscvTextRunSubtract(this.f(136), this.f(128));
    const emptyA = this.f(344) <= 0 || this.f(348) <= 0, emptyB = bw <= 0 || bh <= 0;
    if (emptyA && emptyB) { for (let at = 336; at < 352; at += 4) this.float(at, 0); return; }
    if (emptyB) return;
    if (emptyA) { this.float(336, bx); this.float(340, by); this.float(344, bw); this.float(348, bh); return; }
    const x0 = nscvTextRunMin(this.f(336), bx), y0 = nscvTextRunMin(this.f(340), by), x1 = nscvTextRunMax(nscvTextRunAdd(this.f(336), this.f(344)), nscvTextRunAdd(bx, bw)), y1 = nscvTextRunMax(nscvTextRunAdd(this.f(340), this.f(348)), nscvTextRunAdd(by, bh));
    this.float(336, x0); this.float(340, y0); this.float(344, nscvTextRunSubtract(x1, x0)); this.float(348, nscvTextRunSubtract(y1, y0));
  }

  run(): Uint8Array {
    while (true) {
      if (this.phase === 99) return this.done();
      if (this.phase === 0 && (this.mode === 0 || this.mode === 1)) {
        this.put(288, this.u(44)); this.put(292, this.u(48)); this.put(296, this.u(52));
        if (this.mode === 0 && this.u(52) !== 0) return this.done();
        this.put(144, this.u(44)); this.put(152, this.u(44));
        if (this.mode === 0 && this.glyphCount > 0) {
          let start = this.u(44); while (this.out[4] === 1 && start < this.glyphCount && this.glyphBreak(start)) start++;
          if (start >= this.glyphCount) {
            this.put(296, 1); if (this.u(48) > 0) return this.done(); this.setLine(0, 0, 0, 0); this.put(292, 1); this.phase = 30; continue;
          }
          let end = this.glyphCount, index = start, total = 0, last = -1;
          if (this.out[4] !== 0 && this.width > 0 && this.width !== Infinity) while (index < this.glyphCount) {
            if (this.glyphBreak(index)) last = index;
            const value = nscvTextRunAdd(total, this.advance(index));
            if (value > this.width) { end = index === start ? index + 1 : this.out[4] === 1 && last > start ? last : index; break; }
            total = value; index++;
          }
          const r = this.range(start, end - start); this.setLine(r.run_first_byte, r.run_last_byte - r.run_first_byte, start, end - start);
          this.put(288, end); this.put(292, this.u(48) + 1); this.put(296, 0);
          if (!(this.out[4] === 0 && this.out[6] === 0 && this.width > 0 && this.width !== Infinity && end > start)) { this.phase = 30; continue; }
          total = 0; for (let n = start; n < end; n++) total = nscvTextRunAdd(total, this.advance(n));
          if (total <= nscvTextRunAdd(this.width, 0.125)) { this.phase = 30; continue; }
          return this.ask(24, 5, 0, 0);
        }
        if (this.textLength === 0) { this.endPlain(0); this.phase = this.mode === 1 ? 99 : 30; continue; }
        if (this.out[4] === 0 || !(this.width > 0) || this.width === Infinity) { let end = this.u(144); while (end < this.textLength && this.text[end] !== 10) end++; this.endPlain(end); continue; }
        if (this.hasMeasure) return this.ask(1, 3, 0, this.textLength);
        this.phase = 2;
      }
      if (this.phase === 1) { this.put(168, this.u(120)); this.phase = 2; }
      if (this.phase === 2) {
        const p = this.u(152); if (p >= this.textLength || this.text[p] === 10) { this.endPlain(p); continue; }
        if (this.u(168) !== 0) { this.takeBreakWidth(nscvTextRunAdd(this.f(164), this.f(this.advancesAt + p * 4))); continue; }
        return this.ask(3, 1, this.u(144), this.next(p));
      }
      if (this.phase === 3) { this.takeBreakWidth(this.f(116)); continue; }
      if (this.phase === 10) {
        if (!(this.out[4] === 0 && this.out[6] === 0 && this.width > 0 && this.width !== Infinity && this.u(148) > this.u(144))) { this.phase = 30; continue; }
        if (this.hasMeasure) return this.ask(12, 3, 0, this.textLength);
        this.put(204, 2); return this.ask(11, 5, 0, 0);
      }
      if (this.phase === 12) {
        if (this.u(120) !== 0) { this.put(204, 1); return this.ask(11, 5, 0, 0); }
        return this.ask(14, 1, this.u(144), this.u(148));
      }
      if (this.phase === 14) {
        if (this.f(116) <= nscvTextRunAdd(this.width, 0.125)) { this.float(184, this.f(116)); this.put(188, 1); this.phase = 30; continue; }
        return this.ask(15, 5, 0, 0);
      }
      if (this.phase === 15) {
        this.float(372, this.f(116));
        if (this.f(372) > this.width) { this.float(372, 0); this.elided(0, 0); continue; }
        this.put(152, this.u(144)); this.put(172, this.u(144)); this.float(176, 0); this.phase = 16;
      }
      if (this.phase === 16) { if (this.u(152) >= this.u(148)) { this.phase = 23; continue; } return this.ask(17, 1, this.u(144), this.next(this.u(152))); }
      if (this.phase === 17) {
        if (this.f(116) > nscvTextRunSubtract(this.width, this.f(372))) { this.phase = 23; continue; }
        this.put(152, this.next(this.u(152))); this.put(172, this.u(152)); this.float(176, this.f(116)); this.phase = 16; continue;
      }
      if (this.phase === 23) {
        let end = this.u(172); while (end > this.u(144) && this.isBreak(end - 1)) end--;
        this.put(172, end); if (end === this.u(152)) { this.elided(end - this.u(144), this.f(176)); continue; }
        return this.ask(22, 1, this.u(144), end);
      }
      if (this.phase === 22) { this.elided(this.u(172) - this.u(144), this.f(116)); continue; }
      if (this.phase === 11) { this.float(372, this.f(116)); this.put(152, this.u(144)); this.put(172, this.u(144)); this.float(164, 0); this.float(176, 0); this.phase = 18; }
      if (this.phase === 18) {
        if (this.u(152) < this.u(148)) {
          if (this.u(204) === 1) { this.takeElisionAdvance(this.f(this.advancesAt + this.u(152) * 4)); continue; }
          return this.ask(19, 2, this.u(152), this.next(this.u(152)));
        }
        if (this.f(164) <= nscvTextRunAdd(this.width, 0.125)) { this.float(372, 0); this.float(184, this.f(164)); this.put(188, 1); this.phase = 30; continue; }
        if (this.f(372) > this.width) { this.float(372, 0); this.elided(0, 0); continue; }
        this.float(184, this.f(176)); this.phase = 20;
      }
      if (this.phase === 19) { this.takeElisionAdvance(this.f(116)); continue; }
      if (this.phase === 20) {
        const p = this.u(172); if (p <= this.u(144) || !this.isBreak(p - 1)) { this.elided(p - this.u(144), nscvTextRunMax(0, this.f(184))); continue; }
        if (this.u(204) === 1) { this.float(184, nscvTextRunSubtract(this.f(184), this.f(this.advancesAt + (p - 1) * 4))); this.put(172, p - 1); continue; }
        return this.ask(21, 2, p - 1, p);
      }
      if (this.phase === 21) { this.float(184, nscvTextRunSubtract(this.f(184), this.f(116))); this.put(172, this.u(172) - 1); this.phase = 20; continue; }
      if (this.phase === 24) {
        this.float(372, this.f(116)); this.put(356, 1); this.put(364, 1);
        if (this.f(372) > this.width) { this.put(360, 0); this.put(368, 0); this.float(372, 0); this.phase = 30; continue; }
        let end = this.u(328), total = 0; const limit = this.u(328) + this.u(332);
        while (end < limit) { const value = nscvTextRunAdd(total, this.advance(end)); if (value > nscvTextRunSubtract(this.width, this.f(372))) break; total = value; end++; }
        while (end > this.u(328) && this.glyphBreak(end - 1)) end--;
        const r = this.range(this.u(328), end - this.u(328)); this.put(360, Math.max(0, r.run_last_byte - this.u(320))); this.put(368, end - this.u(328)); this.phase = 30;
      }
      if (this.phase === 0 && this.mode === 4) this.phase = 30;
      if (this.phase === 30) {
        const gs = this.u(328), gl = this.mode === 4 ? this.u(332) : this.u(364) !== 0 ? this.u(368) : this.u(332);
        if (gl > 0 && gs < this.glyphCount) { this.rawGlyphBounds(gs, gl, this.f(352), this.f(348)); return this.finishBounds(); }
        this.float(336, this.ox); this.float(340, nscvTextRunSubtract(this.f(352), this.size));
        if (this.u(188) !== 0 && this.mode === 0) { this.float(344, this.f(184)); return this.finishBounds(); }
        if (this.drawMeasure) return this.ask(31, 4, 0, this.textLength);
        return this.ask(32, 1, this.u(320), Math.min(this.textLength, this.u(320) + (this.u(356) !== 0 ? this.u(360) : this.u(324))));
      }
      if (this.phase === 31) {
        if (this.u(120) === 0) return this.ask(32, 1, this.u(320), Math.min(this.textLength, this.u(320) + (this.u(356) !== 0 ? this.u(360) : this.u(324))));
        let total = 0; const end = Math.min(this.textLength, this.u(320) + (this.u(356) !== 0 ? this.u(360) : this.u(324)));
        for (let n = this.u(320); n < end; n++) total = nscvTextRunAdd(total, this.f(this.advancesAt + n * 4)); this.float(344, total); return this.finishBounds();
      }
      if (this.phase === 32) { this.float(344, this.f(116)); return this.finishBounds(); }
      if (this.phase === 0 && this.mode === 2) {
        const r = this.lineRange(), offset = Math.max(r.run_first_byte, Math.min(r.run_last_byte, this.snap(this.u(56))));
        if (this.u(332) === 0 || this.u(328) >= this.glyphCount) return this.ask(40, 1, r.run_first_byte, offset);
        let x = this.f(336);
        if (r.run_last_byte > r.run_first_byte && offset > r.run_first_byte) {
          if (offset >= r.run_last_byte) x = nscvTextRunAdd(this.f(336), this.f(344));
          else {
            const raw = this.savedRawGlyphBounds();
            if (this.explicitLine()) {
              x = nscvTextRunAdd(this.f(336), this.f(344));
              for (let n = this.u(328); n < Math.min(this.glyphCount, this.u(328) + this.u(332)); n++) {
                const gr = this.range(n, 1); if (gr.run_last_byte <= r.run_first_byte || gr.run_first_byte >= r.run_last_byte) continue;
                const gx = this.glyphX(n, raw.first, raw.dx);
                if (offset <= gr.run_first_byte) { x = gx; break; }
                if (offset < gr.run_last_byte) { const count = this.scalarCount(gr.run_first_byte, gr.run_last_byte); let p = gr.run_first_byte, index = 0; while (p < this.snap(offset)) { p = this.next(p); index++; } x = nscvTextRunAdd(gx, nscvTextRunMultiply(nscvTextRunDivide(Math.fround(Math.min(index, count)), Math.fround(count)), nscvTextRunMax(1, this.advance(n)))); break; }
              }
            } else {
              const count = this.scalarCount(r.run_first_byte, r.run_last_byte); let p = r.run_first_byte, index = 0; while (p < offset) { p = this.next(p); index++; }
              const relative = count === 0 ? 0 : Math.min(this.u(332), this.ratioIndex(index, this.u(332), count, false));
              x = relative === 0 ? this.f(336) : relative >= this.u(332) || this.u(328) + relative >= this.glyphCount ? nscvTextRunAdd(this.f(336), this.f(344)) : this.glyphX(this.u(328) + relative, raw.first, raw.dx);
            }
          }
        }
        this.float(304, this.u(356) !== 0 || this.u(364) !== 0 ? nscvTextRunMin(x, nscvTextRunAdd(this.f(336), this.f(344))) : x); return this.done();
      }
      if (this.phase === 40) { const x = nscvTextRunAdd(this.f(336), this.f(116)); this.float(304, this.u(356) !== 0 || this.u(364) !== 0 ? nscvTextRunMin(x, nscvTextRunAdd(this.f(336), this.f(344))) : x); return this.done(); }
      if (this.phase === 0 && this.mode === 3) {
        const r = this.lineRange(), x = this.f(60), right = nscvTextRunAdd(this.f(336), this.f(344));
        if (x <= this.f(336)) { this.put(308, r.run_first_byte); return this.done(); }
        if (this.u(356) !== 0 || this.u(364) !== 0) {
          if (x >= right) { this.put(308, r.run_last_byte); return this.done(); }
          if (x >= nscvTextRunSubtract(right, this.f(372))) { this.put(308, this.snap(Math.min(r.run_last_byte, this.u(320) + (this.u(356) !== 0 ? this.u(360) : this.u(324))))); return this.done(); }
        }
        if (this.u(332) > 0 && this.u(328) < this.glyphCount) {
          const raw = this.savedRawGlyphBounds(), explicit = this.explicitLine();
          for (let n = this.u(328); n < Math.min(this.glyphCount, this.u(328) + this.u(332)); n++) {
            const gx = this.glyphX(n, raw.first, raw.dx), step = nscvTextRunMax(1, this.advance(n)), gr = this.range(n, 1);
            if (explicit) {
              if (gr.run_last_byte <= r.run_first_byte || gr.run_first_byte >= r.run_last_byte) continue;
              if (x <= gx) { this.put(308, Math.max(r.run_first_byte, gr.run_first_byte)); return this.done(); }
              if (x < nscvTextRunAdd(gx, step)) {
                const count = this.scalarCount(gr.run_first_byte, gr.run_last_byte), value = nscvTextRunDivide(nscvTextRunSubtract(x, gx), step), clamped = Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : 0;
                const index = Math.floor(nscvTextRunAdd(nscvTextRunMultiply(clamped, Math.fround(count)), 0.5)); this.put(308, this.scalarOffset(gr.run_first_byte, gr.run_last_byte, Math.min(index, count))); return this.done();
              }
            } else if (x < nscvTextRunAdd(gx, nscvTextRunMultiply(step, 0.5))) { this.put(308, Math.max(r.run_first_byte, Math.min(r.run_last_byte, this.snap(gr.run_first_byte)))); return this.done(); }
          }
          this.put(308, r.run_last_byte); return this.done();
        }
        this.put(152, r.run_first_byte); this.float(164, this.f(336)); this.phase = 41;
      }
      if (this.phase === 41) { const r = this.lineRange(); if (this.u(152) >= r.run_last_byte) { this.put(308, r.run_last_byte); return this.done(); } return this.ask(42, this.drawMeasure ? 1 : 2, this.drawMeasure ? r.run_first_byte : this.u(152), this.next(this.u(152))); }
      if (this.phase === 42) { this.float(176, this.f(116)); if (this.drawMeasure) return this.ask(43, 1, this.lineRange().run_first_byte, this.u(152)); this.phase = 44; }
      if (this.phase === 43) { this.float(176, nscvTextRunMax(0, nscvTextRunSubtract(this.f(176), this.f(116)))); this.phase = 44; }
      if (this.phase === 44) { const step = nscvTextRunMax(1, this.f(176)); if (this.f(60) < nscvTextRunAdd(this.f(164), nscvTextRunMultiply(step, 0.5))) { this.put(308, this.u(152)); return this.done(); } this.float(164, nscvTextRunAdd(this.f(164), step)); this.put(152, this.next(this.u(152))); this.phase = 41; continue; }
      if (this.phase === 0 && (this.mode === 5 || this.mode === 8)) {
        if (this.glyphCount === 0 && this.textLength === 0) return this.done();
        if (this.glyphCount === 0) return this.ask(50, 1, 0, this.textLength);
        let minX = nscvTextRunAdd(this.ox, this.glyph(0, 0)), maxX = nscvTextRunAdd(minX, this.advance(0)), minY = nscvTextRunSubtract(nscvTextRunAdd(this.oy, this.glyph(0, 4)), this.size), maxY = nscvTextRunAdd(nscvTextRunAdd(this.oy, this.glyph(0, 4)), nscvTextRunMultiply(this.size, 0.25));
        for (let n = 1; n < this.glyphCount; n++) {
          const x = nscvTextRunAdd(this.ox, this.glyph(n, 0)), y = nscvTextRunAdd(this.oy, this.glyph(n, 4));
          minX = nscvTextRunMin(minX, x); maxX = nscvTextRunMax(maxX, nscvTextRunAdd(x, this.advance(n))); minY = nscvTextRunMin(minY, nscvTextRunSubtract(y, this.size)); maxY = nscvTextRunMax(maxY, nscvTextRunAdd(y, nscvTextRunMultiply(this.size, 0.25)));
        }
        this.float(336, minX); this.float(340, minY); this.float(344, nscvTextRunMax(nscvTextRunMultiply(this.size, 0.25), nscvTextRunSubtract(maxX, minX))); this.float(348, nscvTextRunMax(nscvTextRunMultiply(this.size, 1.25), nscvTextRunSubtract(maxY, minY)));
        if (this.mode === 8) this.inflate(); this.put(300, 1); return this.done();
      }
      if (this.phase === 50) {
        this.float(336, this.ox); this.float(340, nscvTextRunSubtract(this.oy, this.size)); this.float(344, nscvTextRunMax(nscvTextRunMultiply(this.size, 0.25), nscvTextRunSubtract(nscvTextRunAdd(this.ox, this.f(116)), this.ox))); this.float(348, nscvTextRunMax(nscvTextRunMultiply(this.size, 1.25), nscvTextRunSubtract(nscvTextRunAdd(this.oy, nscvTextRunMultiply(this.size, 0.25)), nscvTextRunSubtract(this.oy, this.size))));
        this.put(300, 1);
        if (this.mode === 8) { this.inflate(); if (this.drawMeasure) return this.ask(62, 6, 0, this.textLength); }
        return this.done();
      }
      if (this.phase === 0 && this.mode === 6) {
        this.put(300, 1); if (this.glyphCount > 0 || !this.drawMeasure) return this.done();
        this.float(220, this.f(336)); this.float(224, nscvTextRunAdd(this.f(336), this.f(344)));
        const start = Math.min(this.u(320), this.textLength), end = Math.min(this.textLength, start + (this.u(356) !== 0 ? this.u(360) : this.u(324)));
        if (end > start) return this.ask(60, 6, start, end);
        this.phase = 63;
      }
      if (this.phase === 60) { this.unionInk(this.f(220), this.f(352)); this.phase = 63; }
      if (this.phase === 63) { if ((this.u(356) !== 0 || this.u(364) !== 0) && this.f(372) > 0) return this.ask(61, 7, 0, 0); return this.done(); }
      if (this.phase === 61) { this.unionInk(nscvTextRunSubtract(this.f(224), this.f(372)), this.f(352)); return this.done(); }
      if (this.phase === 62) { this.unionInk(this.ox, this.oy); return this.done(); }
      if (this.phase === 0 && this.mode === 7) { this.inflate(); this.put(300, 1); return this.done(); }
      throw new Error("invalid text run phase");
    }
  }
}

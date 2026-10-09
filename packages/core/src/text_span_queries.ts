// Rich paragraph query coordination. Source facts and the bounded paragraph
// scratch page belong to the caller; continuations copy only this fixed state.
function nscvTextSpanQueries(request: Uint8Array): Uint8Array {
  return new NscTextSpanQueryContext(request).plan();
}

// One copied continuation keeps helpers receiver-bound rather than captured.
class NscTextSpanQueryContext {
  readonly request: Uint8Array;
  readonly out: Uint8Array;
  readonly w: DataView;
  readonly facts: DataView;
  readonly mode: number;
  readonly spans: number;
  readonly spanAt: number;
  readonly runAt: number;
  readonly paragraphAt: number;
  readonly paragraphLen: number;
  readonly clipLen: number;
  constructor(request: Uint8Array) {
    if (request.length < 512 || request[0] !== 56 || request[1] !== 1 || request[2]! > 2 || request[3]! > 1)
      throw new Error("invalid span query header");
    const out = request.slice(0, 512), w = new DataView(out.buffer);
    const facts = new DataView(request.buffer, request.byteOffset, request.byteLength);

    const mode = out[2]!, spans = w.getUint32(28, true), spanAt = w.getUint32(24, true), runAt = w.getUint32(32, true), paragraphAt = w.getUint32(16, true), paragraphLen = w.getUint32(20, true), clipLen = w.getUint32(40, true);
    if (w.getUint32(12, true) !== request.length || spanAt !== 512 || runAt !== spanAt + spans * 16 || w.getUint32(36, true) < runAt + 160 * 32 ||
        paragraphAt !== w.getUint32(36, true) + clipLen * 4 || paragraphLen > request.length - paragraphAt || w.getUint32(96, true) > 1 || w.getUint32(104, true) > 1 ||
        w.getUint32(152, true) > 160 || w.getUint32(156, true) > 160 || w.getUint32(164, true) > w.getUint32(8, true)) throw new Error("invalid span query storage");
    let end = paragraphAt + paragraphLen;
    for (let s = 0; s < spans; s++) {
      const at = spanAt + s * 16;
      if (facts.getUint32(at, true) !== end || facts.getUint32(at + 4, true) > request.length - end || facts.getUint32(at + 12, true) > 1 ||
          (facts.getUint32(at + 12, true) !== 0 && (facts.getUint32(at + 8, true) > paragraphLen || facts.getUint32(at + 4, true) > paragraphLen - facts.getUint32(at + 8, true))))
        throw new Error("invalid span source facts");
      end += facts.getUint32(at + 4, true);
    }
    if (w.getUint32(36, true) !== runAt + 160 * 32 + clipLen || end !== request.length) throw new Error("invalid span query extent");

    this.request = request;
    this.out = out;
    this.w = w;
    this.facts = facts;
    this.mode = mode;
    this.spans = spans;
    this.spanAt = spanAt;
    this.runAt = runAt;
    this.paragraphAt = paragraphAt;
    this.paragraphLen = paragraphLen;
    this.clipLen = clipLen;
  }
  byte(at: number, len: number, i: number): number {
    if (i < 0 || i >= len || at > this.request.length || len > this.request.length - at) throw new Error("invalid span byte cursor");
    return this.request[at + i]!;
  }
  snap(at: number, len: number, p: number): number {
    let c = Math.min(p, len); while (c > 0 && c < len && (this.byte(at, len, c) & 0xc0) === 0x80) c--; return c;
  }
  previous(at: number, len: number, p: number): number {
    let c = this.snap(at, len, p); if (c === 0) return 0; c--; while (c > 0 && (this.byte(at, len, c) & 0xc0) === 0x80) c--; return c;
  }
  next(at: number, len: number, p: number): number {
    const c = this.snap(at, len, p); if (c === len) return c; const lead = this.byte(at, len, c);
    const result = Math.min(len, c + ((lead & 0x80) === 0 ? 1 : (lead & 0xe0) === 0xc0 ? 2 : (lead & 0xf0) === 0xe0 ? 3 : (lead & 0xf8) === 0xf0 ? 4 : 1));
    return result <= p ? Math.min(len, p + 1) : result;
  }
  spanRun(slot: number): number {
    if (slot >= 160) throw new Error("invalid span run slot"); const at = this.runAt + slot * 32;
    if (this.facts.getUint32(at, true) >= this.spans || this.facts.getUint32(at + 4, true) > this.request.length || this.facts.getUint32(at + 8, true) > this.request.length - this.facts.getUint32(at + 4, true) || this.facts.getUint32(at + 28, true) > 1 ||
        (this.facts.getUint32(at + 28, true) !== 0 && (this.facts.getUint32(at + 24, true) > this.paragraphLen || this.facts.getUint32(at + 8, true) > this.paragraphLen - this.facts.getUint32(at + 24, true))))
      throw new Error("invalid span run facts");
    return at;
  }
  done(present: boolean): Uint8Array { this.w.setUint32(80, 0, true); this.w.setUint32(96, 0, true); this.w.setUint32(112, present ? 1 : 0, true); this.out[3] = 2; return this.out; }
  ask(kind: number, slot: number, first: number, last: number, phase: number): Uint8Array {
    this.w.setUint32(80, kind, true); this.w.setUint32(84, slot, true); this.w.setUint32(88, first, true); this.w.setUint32(92, last, true); this.w.setUint32(96, 0, true); this.w.setFloat32(100, 0, true); this.w.setUint32(104, 0, true); this.w.setUint32(108, phase, true); this.out[3] = 1; return this.out;
  }
  layout(page: number, phase: number): Uint8Array { return this.ask(1, page * 128, 0, 0, phase); }
  measure(slot: number, prefix: number, phase: number): Uint8Array {
    const at = this.spanRun(slot); if (prefix > this.facts.getUint32(at + 8, true)) throw new Error("invalid span prefix"); return this.ask(3, slot, 0, prefix, phase);
  }
  pageEnd(): number {
    let value = 4294967295; for (let i = 0; i < this.w.getUint32(152, true); i++) { const at = this.spanRun(i); if (this.facts.getUint32(at + 28, true) !== 0) value = Math.max(value === 4294967295 ? 0 : value, this.facts.getUint32(at + 24, true) + this.facts.getUint32(at + 8, true)); } return value;
  }
  sourceEnd(p: number): number {
    let c = Math.min(p, this.paragraphLen); while (c < this.paragraphLen && (this.byte(this.paragraphAt, this.paragraphLen, c) === 32 || this.byte(this.paragraphAt, this.paragraphLen, c) === 9)) c++;
    if (c < this.paragraphLen && this.byte(this.paragraphAt, this.paragraphLen, c) === 13) c++;
    if (c < this.paragraphLen && this.byte(this.paragraphAt, this.paragraphLen, c) === 10) c++; return c;
  }
  boundary(target: number, continuation: number): void {
    this.w.setUint32(204, continuation, true); this.w.setUint32(208, 0, true); this.w.setUint32(212, this.clipLen, true); this.w.setFloat32(216, target, true);
    if (target <= 0) { this.w.setUint32(200, 0, true); this.w.setUint32(108, continuation, true); }
    else if (target >= this.w.getFloat32(60, true)) { this.w.setUint32(200, this.clipLen, true); this.w.setUint32(108, continuation, true); }
    else this.w.setUint32(108, 11, true);
  }
  flush(phase: number): Uint8Array {
    const left = this.w.getFloat32(228, true), right = this.w.getFloat32(232, true), top = Math.fround(Math.fround(this.w.getUint32(224, true)) * this.w.getFloat32(160, true));
    let a = this.w.getUint32(236, true), b = this.w.getUint32(240, true), x = left, y = top, width = nscvShellMax(1, Math.fround(right - left)), height = nscvShellMax(1, this.w.getFloat32(160, true));
    const count = this.w.getUint32(164, true), slot = count < this.w.getUint32(8, true) ? count : count - 1;
    if (count >= this.w.getUint32(8, true)) {
      a = this.w.getUint32(280, true); x = nscvShellMin(this.w.getFloat32(288, true), x); y = nscvShellMin(this.w.getFloat32(292, true), y);
      width = Math.fround(nscvShellMax(Math.fround(this.w.getFloat32(288, true) + this.w.getFloat32(296, true)), Math.fround(left + width)) - x);
      height = Math.fround(nscvShellMax(Math.fround(this.w.getFloat32(292, true) + this.w.getFloat32(300, true)), Math.fround(top + height)) - y);
    } else this.w.setUint32(164, count + 1, true);
    this.w.setUint32(280, a, true); this.w.setUint32(284, b, true); this.w.setFloat32(288, x, true); this.w.setFloat32(292, y, true); this.w.setFloat32(296, width, true); this.w.setFloat32(300, height, true);
    this.w.setUint32(116, a, true); this.w.setUint32(120, b, true); this.w.setFloat32(128, x, true); this.w.setFloat32(132, y, true); this.w.setFloat32(136, width, true); this.w.setFloat32(140, height, true);
    return this.ask(5, slot, 0, 0, phase);
  }

  plan(): Uint8Array {
    let phase = this.w.getUint32(108, true);
    if (phase === 0) {
      if (this.out[3] !== 0) throw new Error("invalid span query initial status");
      for (let at = 80; at < 512; at += 4) if (this.w.getUint32(at, true) !== 0) throw new Error("invalid span query initial state");
      if (this.mode === 0) {
        if (this.clipLen === 0) return this.done(false);
        if (!Number.isFinite(this.w.getFloat32(64, true)) || !Number.isFinite(this.w.getFloat32(68, true)) || (this.w.getFloat32(64, true) <= 0 && this.w.getFloat32(68, true) >= this.w.getFloat32(60, true))) { this.w.setUint32(116, 0, true); this.w.setUint32(120, this.clipLen, true); return this.done(true); }
        return this.ask(2, 0, 0, this.clipLen, 1);
      }
      if (this.mode === 2) {
        const a = this.snap(this.paragraphAt, this.paragraphLen, Math.min(this.w.getUint32(44, true), this.w.getUint32(48, true))), b = this.snap(this.paragraphAt, this.paragraphLen, Math.max(this.w.getUint32(44, true), this.w.getUint32(48, true)));
        this.w.setUint32(172, a, true); this.w.setUint32(176, b, true); if (a === b || this.w.getUint32(8, true) === 0) return this.done(false);
      }
      return this.layout(0, this.mode === 1 ? 21 : 31);
    }
    if (this.out[3] !== 1 || this.w.getUint32(96, true) !== 1) throw new Error("span query reply missing");
    const action = this.w.getUint32(80, true);
    if (this.mode === 0 ? ![1, 10, 12, 15, 16, 19, 20].includes(phase) : this.mode === 1 ? ![21, 22, 25, 28].includes(phase) : ![31, 33, 35, 37, 39, 41, 42, 43, 45].includes(phase))
      throw new Error("invalid span query reply phase");
    const expected = phase === 1 ? 2 : phase === 28 ? 4 : phase === 43 || phase === 45 ? 5 : phase === 21 || phase === 22 || phase === 31 || phase === 33 || phase === 35 || phase === 37 || phase === 39 ? 1 : 3;
    if (action !== expected) throw new Error("invalid span query reply action");
    for (let at = 344; at < 512; at += 4) if (this.w.getUint32(at, true) !== 0) throw new Error("invalid span query reserved state");
    this.w.setUint32(96, 0, true);
    while (true) {
      phase = this.w.getUint32(108, true);
      if (phase === 1) {
        if (this.w.getUint32(104, true) !== 0) {
          const at = this.spanRun(0), textAt = this.facts.getUint32(at + 4, true); let c = 0, x = 0, prev = 4294967295, prevX = 0, first = 0, firstX = 0, found = false, guard = false;
          while (c < this.clipLen) {
            const n = this.next(textAt, this.clipLen, c); let advance = 0; for (let i = c; i < n; i++) advance = Math.fround(advance + this.facts.getFloat32(this.w.getUint32(36, true) + i * 4, true)); advance = nscvShellMax(0, advance);
            if (Number.isFinite(advance) && advance > 0) {
              if (!found && Math.fround(x + advance) > nscvShellMax(0, this.w.getFloat32(64, true))) { first = prev === 4294967295 ? c : prev; firstX = prev === 4294967295 ? x : prevX; found = true; }
              if (found && x >= this.w.getFloat32(68, true)) {
                if (guard) { this.w.setUint32(116, first, true); this.w.setUint32(120, c, true); this.w.setFloat32(128, firstX, true); return this.done(first < c); } guard = true;
              }
              prev = c; prevX = x;
            }
            x = Math.fround(x + advance); c = n;
          }
          if (!found) { this.w.setUint32(116, 0, true); this.w.setUint32(120, this.clipLen, true); return this.done(x <= 0); }
          this.w.setUint32(116, first, true); this.w.setUint32(120, this.clipLen, true); this.w.setFloat32(128, firstX, true); return this.done(true);
        }
        this.boundary(nscvShellMax(0, this.w.getFloat32(64, true)), 13); continue;
      }
      if (phase === 11) {
        const at = this.spanRun(0), textAt = this.facts.getUint32(at + 4, true), low = this.w.getUint32(208, true), high = this.w.getUint32(212, true);
        if (this.next(textAt, this.clipLen, low) >= high) { this.w.setUint32(200, high, true); this.w.setUint32(108, this.w.getUint32(204, true), true); continue; }
        let middle = this.snap(textAt, this.clipLen, low + Math.floor((high - low) / 2));
        if (middle <= low) middle = this.next(textAt, this.clipLen, low); if (middle >= high) middle = this.previous(textAt, this.clipLen, high);
        if (middle <= low || middle >= high) { this.w.setUint32(200, high, true); this.w.setUint32(108, this.w.getUint32(204, true), true); continue; }
        this.w.setUint32(220, middle, true); return this.measure(0, middle, 12);
      }
      if (phase === 12) { this.w.setUint32(this.w.getFloat32(100, true) < this.w.getFloat32(216, true) ? 208 : 212, this.w.getUint32(220, true), true); this.w.setUint32(108, 11, true); continue; }
      if (phase === 13) {
        if (this.w.getUint32(200, true) === this.clipLen && this.w.getFloat32(64, true) >= this.w.getFloat32(60, true)) return this.done(false);
        const at = this.spanRun(0), visible = this.previous(this.facts.getUint32(at + 4, true), this.clipLen, this.w.getUint32(200, true)); this.w.setUint32(224, visible, true); this.w.setUint32(228, visible, true); this.w.setUint32(108, 14, true); continue;
      }
      if (phase === 14) {
        if (this.w.getUint32(228, true) === 0) { this.w.setUint32(116, this.w.getUint32(224, true), true); this.boundary(this.w.getFloat32(68, true), 17); continue; }
        const at = this.spanRun(0), p = this.previous(this.facts.getUint32(at + 4, true), this.clipLen, this.w.getUint32(228, true)); this.w.setUint32(232, p, true); return this.measure(0, this.next(this.facts.getUint32(at + 4, true), this.clipLen, p), 15);
      }
      if (phase === 15) { this.w.setFloat32(236, this.w.getFloat32(100, true), true); return this.measure(0, this.w.getUint32(232, true), 16); }
      if (phase === 16) {
        if (nscvShellMax(0, Math.fround(this.w.getFloat32(236, true) - this.w.getFloat32(100, true))) > 0) { this.w.setUint32(116, this.w.getUint32(232, true), true); this.boundary(this.w.getFloat32(68, true), 17); }
        else { this.w.setUint32(228, this.w.getUint32(232, true), true); this.w.setUint32(108, 14, true); } continue;
      }
      if (phase === 17) { this.w.setUint32(228, this.w.getUint32(200, true), true); this.w.setUint32(240, 0, true); this.w.setUint32(108, 18, true); continue; }
      if (phase === 18) {
        if (this.w.getUint32(228, true) >= this.clipLen) { this.w.setUint32(120, this.clipLen, true); if (this.w.getUint32(116, true) >= this.clipLen) return this.done(false); return this.measure(0, this.w.getUint32(116, true), 20); }
        const at = this.spanRun(0); return this.measure(0, this.next(this.facts.getUint32(at + 4, true), this.clipLen, this.w.getUint32(228, true)), 19);
      }
      if (phase === 19) { this.w.setFloat32(236, this.w.getFloat32(100, true), true); return this.measure(0, this.w.getUint32(228, true), 10); }
      if (phase === 10) {
        if (nscvShellMax(0, Math.fround(this.w.getFloat32(236, true) - this.w.getFloat32(100, true))) > 0) {
          if (this.w.getUint32(240, true) !== 0) { this.w.setUint32(120, this.w.getUint32(228, true), true); if (this.w.getUint32(116, true) >= this.w.getUint32(228, true)) return this.done(false); return this.measure(0, this.w.getUint32(116, true), 20); } this.w.setUint32(240, 1, true);
        }
        const at = this.spanRun(0); this.w.setUint32(228, this.next(this.facts.getUint32(at + 4, true), this.clipLen, this.w.getUint32(228, true)), true); this.w.setUint32(108, 18, true); continue;
      }
      if (phase === 20) { this.w.setFloat32(128, this.w.getFloat32(100, true), true); return this.done(this.w.getUint32(116, true) < this.w.getUint32(120, true)); }
      if (phase === 21) {
        if (this.w.getUint32(144, true) === 0 || this.w.getFloat32(148, true) <= 0) return this.done(false);
        const rawLine = Math.fround(this.w.getFloat32(56, true) / this.w.getFloat32(148, true)); if (!(rawLine < 0) && !Number.isFinite(rawLine)) throw new Error("invalid paragraph point line");
        const line = rawLine < 0 ? 0 : Math.min(this.w.getUint32(144, true) - 1, Math.floor(rawLine)); this.w.setUint32(168, line, true);
        if (line >= 128) return this.ask(1, line, 0, 0, 22); this.w.setUint32(108, 22, true); continue;
      }
      if (phase === 22) {
        if (this.w.getUint32(152, true) === 0) {
          let white = this.paragraphLen !== 0, count = 1;
          for (let i = 0; i < this.paragraphLen; i++) { const b = this.byte(this.paragraphAt, this.paragraphLen, i); if (b !== 10 && b !== 13 && b !== 32 && b !== 9) white = false; if (b === 10) count++; }
          if (!white) { this.w.setUint32(116, this.paragraphLen, true); return this.done(this.paragraphLen !== 0); }
          if (this.byte(this.paragraphAt, this.paragraphLen, this.paragraphLen - 1) === 10) count--;
          const raw = Math.fround(this.w.getFloat32(56, true) / this.w.getFloat32(148, true)), line = raw < 0 ? 0 : Math.min(count - 1, Math.floor(raw));
          let a = 0, b = 0, current = 0; while (current < line && a < this.paragraphLen) { while (a < this.paragraphLen && this.byte(this.paragraphAt, this.paragraphLen, a) !== 10) a++; a = Math.min(this.paragraphLen, a + 1); current++; }
          b = a; while (b < this.paragraphLen && this.byte(this.paragraphAt, this.paragraphLen, b) !== 10) b++; if (b < this.paragraphLen) b++;
          this.w.setUint32(172, a, true); this.w.setUint32(176, b, true); this.w.setUint32(180, a, true); this.w.setUint32(184, b > a && this.byte(this.paragraphAt, this.paragraphLen, b - 1) === 10 ? b - 1 : b, true); this.w.setUint32(188, 0, true); this.w.setFloat32(192, 0, true); this.w.setUint32(108, 27, true); continue;
        }
        this.w.setUint32(212, 0, true); this.w.setUint32(304, 4294967295, true); this.w.setUint32(312, 4294967295, true); this.w.setUint32(316, 4294967295, true); this.w.setUint32(108, 23, true); continue;
      }
      if (phase === 23) {
        if (this.w.getUint32(212, true) >= this.w.getUint32(152, true)) {
          if (this.w.getUint32(304, true) !== 4294967295) { this.w.setUint32(116, this.w.getUint32(304, true), true); return this.done(true); }
          if (this.w.getUint32(312, true) === 4294967295) {
            for (let i = 0; i < this.w.getUint32(152, true); i++) { const at = this.spanRun(i); if (this.facts.getUint32(at + 12, true) < this.w.getUint32(168, true)) continue; if (this.facts.getUint32(at + 28, true) === 0) return this.done(false); this.w.setUint32(116, this.facts.getUint32(at + 24, true), true); return this.done(true); }
            for (let i = this.w.getUint32(152, true); i > 0; i--) { const at = this.spanRun(i - 1); if (this.facts.getUint32(at + 28, true) === 0) return this.done(false); this.w.setUint32(116, this.facts.getUint32(at + 24, true) + this.facts.getUint32(at + 8, true), true); return this.done(true); }
            return this.done(false);
          }
          this.w.setUint32(116, this.w.getFloat32(52, true) >= this.w.getFloat32(324, true) ? this.sourceEnd(this.w.getUint32(316, true)) : this.w.getUint32(312, true), true); return this.done(true);
        }
        const at = this.spanRun(this.w.getUint32(212, true)); if (this.facts.getUint32(at + 12, true) !== this.w.getUint32(168, true)) { this.w.setUint32(212, this.w.getUint32(212, true) + 1, true); continue; }
        if (this.facts.getUint32(at + 28, true) === 0) return this.done(false);
        if (this.w.getUint32(312, true) === 4294967295) { this.w.setUint32(312, this.facts.getUint32(at + 24, true), true); this.w.setFloat32(320, this.facts.getFloat32(at + 16, true), true); }
        this.w.setUint32(316, this.facts.getUint32(at + 24, true) + this.facts.getUint32(at + 8, true), true); this.w.setFloat32(324, Math.fround(this.facts.getFloat32(at + 16, true) + this.facts.getFloat32(at + 20, true)), true);
        if (this.w.getFloat32(52, true) >= this.facts.getFloat32(at + 16, true) && this.w.getFloat32(52, true) < this.w.getFloat32(324, true)) { this.w.setFloat32(244, Math.fround(this.w.getFloat32(52, true) - this.facts.getFloat32(at + 16, true)), true); this.w.setUint32(248, 0, true); this.w.setFloat32(252, 0, true); this.w.setUint32(108, 24, true); }
        else this.w.setUint32(212, this.w.getUint32(212, true) + 1, true); continue;
      }
      if (phase === 24) {
        const at = this.spanRun(this.w.getUint32(212, true)), n = this.next(this.facts.getUint32(at + 4, true), this.facts.getUint32(at + 8, true), this.w.getUint32(248, true));
        if (this.w.getUint32(248, true) >= this.facts.getUint32(at + 8, true) || this.w.getFloat32(244, true) <= 0) { this.w.setUint32(304, this.facts.getUint32(at + 24, true) + (this.w.getFloat32(244, true) <= 0 ? 0 : this.facts.getUint32(at + 8, true)), true); this.w.setUint32(212, this.w.getUint32(212, true) + 1, true); this.w.setUint32(108, 23, true); continue; }
        this.w.setUint32(256, n, true); return this.measure(this.w.getUint32(212, true), n, 25);
      }
      if (phase === 25) {
        const nx = nscvShellMax(Math.fround(this.w.getFloat32(252, true) + 1), this.w.getFloat32(100, true));
        if (this.w.getFloat32(244, true) < Math.fround(Math.fround(this.w.getFloat32(252, true) + nx) * 0.5)) { const at = this.spanRun(this.w.getUint32(212, true)); this.w.setUint32(304, this.facts.getUint32(at + 24, true) + this.w.getUint32(248, true), true); this.w.setUint32(212, this.w.getUint32(212, true) + 1, true); this.w.setUint32(108, 23, true); }
        else { this.w.setFloat32(252, nx, true); this.w.setUint32(248, this.w.getUint32(256, true), true); this.w.setUint32(108, 24, true); } continue;
      }
      if (phase === 27) {
        if (this.w.getUint32(172, true) >= this.w.getUint32(184, true) || this.w.getUint32(188, true) >= this.spans) { this.w.setUint32(108, 29, true); continue; }
        const s = this.w.getUint32(188, true), at = this.spanAt + s * 16; if (this.facts.getUint32(at + 12, true) === 0) { this.w.setFloat32(192, 0, true); this.w.setUint32(108, 29, true); continue; }
        const a = Math.max(this.w.getUint32(172, true), this.facts.getUint32(at + 8, true)), b = Math.min(this.w.getUint32(184, true), this.facts.getUint32(at + 8, true) + this.facts.getUint32(at + 4, true));
        if (a >= b) { this.w.setUint32(188, s + 1, true); continue; }
        if (a > this.w.getUint32(180, true)) { this.w.setFloat32(192, 0, true); this.w.setUint32(108, 29, true); continue; }
        this.w.setUint32(196, b, true); return this.ask(4, s, a - this.facts.getUint32(at + 8, true), b - this.facts.getUint32(at + 8, true), 28);
      }
      if (phase === 28) { this.w.setFloat32(192, Math.fround(this.w.getFloat32(192, true) + this.w.getFloat32(100, true)), true); this.w.setUint32(180, Math.max(this.w.getUint32(180, true), this.w.getUint32(196, true)), true); if (this.w.getUint32(180, true) >= this.w.getUint32(184, true)) this.w.setUint32(108, 29, true); else { this.w.setUint32(188, this.w.getUint32(188, true) + 1, true); this.w.setUint32(108, 27, true); } continue; }
      if (phase === 29) {
        const width = this.w.getUint32(180, true) >= this.w.getUint32(184, true) ? this.w.getFloat32(192, true) : 0, midpoint = width > 0 ? Math.fround(width * 0.5) : this.w.getFloat32(72, true) > 0 && Number.isFinite(this.w.getFloat32(72, true)) ? Math.fround(this.w.getFloat32(72, true) * 0.5) : 0;
        this.w.setUint32(116, this.w.getFloat32(52, true) < midpoint ? this.w.getUint32(172, true) : this.w.getUint32(176, true), true); return this.done(true);
      }
      if (phase === 31) {
        if (this.w.getUint32(144, true) === 0 || this.w.getFloat32(148, true) <= 0) return this.done(false);
        this.w.setUint32(156, this.w.getUint32(152, true), true); this.w.setFloat32(160, this.w.getFloat32(148, true), true); this.w.setUint32(180, 0, true); this.w.setUint32(184, Math.floor((this.w.getUint32(144, true) + 127) / 128), true); this.w.setUint32(188, 4294967295, true); this.w.setUint32(108, 32, true); continue;
      }
      if (phase === 32) {
        if (this.w.getUint32(180, true) >= this.w.getUint32(184, true)) { this.w.setUint32(208, this.w.getUint32(188, true), true); this.w.setUint32(108, 38, true); continue; }
        const middle = this.w.getUint32(180, true) + Math.floor((this.w.getUint32(184, true) - this.w.getUint32(180, true)) / 2); this.w.setUint32(192, middle, true); return this.layout(middle, 33);
      }
      if (phase === 33) {
        const end = this.pageEnd();
        if (end !== 4294967295) { if (end <= this.w.getUint32(172, true)) this.w.setUint32(180, this.w.getUint32(192, true) + 1, true); else { this.w.setUint32(188, this.w.getUint32(192, true), true); this.w.setUint32(184, this.w.getUint32(192, true), true); } this.w.setUint32(108, 32, true); }
        else { this.w.setUint32(200, this.w.getUint32(192, true), true); this.w.setUint32(108, 34, true); } continue;
      }
      if (phase === 34) {
        if (this.w.getUint32(200, true) <= this.w.getUint32(180, true)) { this.w.setUint32(204, this.w.getUint32(192, true) + 1, true); this.w.setUint32(108, 36, true); continue; }
        this.w.setUint32(200, this.w.getUint32(200, true) - 1, true); return this.layout(this.w.getUint32(200, true), 35);
      }
      if (phase === 35) {
        const end = this.pageEnd(); if (end === 4294967295) this.w.setUint32(108, 34, true);
        else if (end > this.w.getUint32(172, true)) { this.w.setUint32(188, this.w.getUint32(200, true), true); this.w.setUint32(184, this.w.getUint32(200, true), true); this.w.setUint32(108, 32, true); }
        else { this.w.setUint32(204, this.w.getUint32(192, true) + 1, true); this.w.setUint32(108, 36, true); } continue;
      }
      if (phase === 36) {
        if (this.w.getUint32(204, true) >= this.w.getUint32(184, true)) { this.w.setUint32(208, this.w.getUint32(188, true), true); this.w.setUint32(108, 38, true); continue; } return this.layout(this.w.getUint32(204, true), 37);
      }
      if (phase === 37) {
        const end = this.pageEnd(); if (end === 4294967295) { this.w.setUint32(204, this.w.getUint32(204, true) + 1, true); this.w.setUint32(108, 36, true); }
        else if (end > this.w.getUint32(172, true)) { this.w.setUint32(208, this.w.getUint32(204, true), true); this.w.setUint32(108, 38, true); }
        else { this.w.setUint32(180, this.w.getUint32(204, true) + 1, true); this.w.setUint32(108, 32, true); } continue;
      }
      if (phase === 38) {
        if (this.w.getUint32(208, true) === 4294967295) return this.done(false);
        if (this.w.getUint32(208, true) === 0) { this.w.setUint32(152, this.w.getUint32(156, true), true); this.w.setUint32(108, 39, true); continue; } return this.layout(this.w.getUint32(208, true), 39);
      }
      if (phase === 39) { this.w.setUint32(212, 0, true); this.w.setUint32(216, 0, true); this.w.setUint32(224, 4294967295, true); this.w.setUint32(108, 40, true); continue; }
      if (phase === 40) {
        if (this.w.getUint32(212, true) >= this.w.getUint32(152, true)) { if (this.w.getUint32(224, true) !== 4294967295) return this.flush(45); this.w.setUint32(108, 45, true); continue; }
        const at = this.spanRun(this.w.getUint32(212, true)); if (this.facts.getUint32(at + 28, true) === 0) { this.w.setUint32(212, this.w.getUint32(212, true) + 1, true); continue; }
        this.w.setUint32(216, Math.max(this.w.getUint32(216, true), this.facts.getUint32(at + 24, true) + this.facts.getUint32(at + 8, true)), true);
        const a = Math.max(this.w.getUint32(172, true), this.facts.getUint32(at + 24, true)), b = Math.min(this.w.getUint32(176, true), this.facts.getUint32(at + 24, true) + this.facts.getUint32(at + 8, true));
        if (a >= b) { this.w.setUint32(212, this.w.getUint32(212, true) + 1, true); continue; } this.w.setUint32(260, a, true); this.w.setUint32(264, b, true); return this.measure(this.w.getUint32(212, true), a - this.facts.getUint32(at + 24, true), 41);
      }
      if (phase === 41) { const at = this.spanRun(this.w.getUint32(212, true)); this.w.setFloat32(268, Math.fround(this.facts.getFloat32(at + 16, true) + this.w.getFloat32(100, true)), true); return this.measure(this.w.getUint32(212, true), this.w.getUint32(264, true) - this.facts.getUint32(at + 24, true), 42); }
      if (phase === 42) {
        const at = this.spanRun(this.w.getUint32(212, true)), x1 = Math.fround(this.facts.getFloat32(at + 16, true) + this.w.getFloat32(100, true)); this.w.setFloat32(272, x1, true);
        if (this.w.getUint32(224, true) === this.facts.getUint32(at + 12, true)) { this.w.setFloat32(228, nscvShellMin(this.w.getFloat32(228, true), nscvShellMin(this.w.getFloat32(268, true), x1)), true); this.w.setFloat32(232, nscvShellMax(this.w.getFloat32(232, true), nscvShellMax(this.w.getFloat32(268, true), x1)), true); this.w.setUint32(236, Math.min(this.w.getUint32(236, true), this.w.getUint32(260, true)), true); this.w.setUint32(240, Math.max(this.w.getUint32(240, true), this.w.getUint32(264, true)), true); this.w.setUint32(212, this.w.getUint32(212, true) + 1, true); this.w.setUint32(108, 40, true); continue; }
        if (this.w.getUint32(224, true) !== 4294967295) return this.flush(43); this.w.setUint32(108, 43, true); continue;
      }
      if (phase === 43) {
        const at = this.spanRun(this.w.getUint32(212, true)); this.w.setUint32(224, this.facts.getUint32(at + 12, true), true); this.w.setFloat32(228, nscvShellMin(this.w.getFloat32(268, true), this.w.getFloat32(272, true)), true); this.w.setFloat32(232, nscvShellMax(this.w.getFloat32(268, true), this.w.getFloat32(272, true)), true); this.w.setUint32(236, this.w.getUint32(260, true), true); this.w.setUint32(240, this.w.getUint32(264, true), true); this.w.setUint32(212, this.w.getUint32(212, true) + 1, true); this.w.setUint32(108, 40, true); continue;
      }
      if (phase === 45) {
        if (this.w.getUint32(216, true) >= this.w.getUint32(176, true) || this.w.getUint32(208, true) + 1 >= Math.floor((this.w.getUint32(144, true) + 127) / 128)) return this.done(this.w.getUint32(164, true) !== 0);
        this.w.setUint32(208, this.w.getUint32(208, true) + 1, true); return this.layout(this.w.getUint32(208, true), 39);
      }
      throw new Error("invalid span query phase");
    }
}
}


// Round an exact unsigned 64-bit identity/index to f32 without an intervening
// lossy f64 conversion. Halfway values follow ties-to-even as native does.
function nscvSpanLineFloat(low: number, high: number): number {
  if (high === 0) return Math.fround(low);
  let exponent = 32, power = 1;
  while (power * 2 <= high) { power *= 2; exponent++; }
  const shift = exponent - 23, divisor = 2 ** shift;
  let mantissa: number, above: boolean, tie: boolean;
  if (shift <= 32) {
    mantissa = high * (4294967296 / divisor) + Math.floor(low / divisor);
    const remainder = low % divisor; above = remainder > divisor * 0.5; tie = remainder === divisor * 0.5;
  } else {
    const upperDivisor = 2 ** (shift - 32), remainder = high % upperDivisor;
    mantissa = Math.floor(high / upperDivisor); above = remainder > upperDivisor * 0.5 || (remainder === upperDivisor * 0.5 && low !== 0);
    tie = remainder === upperDivisor * 0.5 && low === 0;
  }
  if (above || (tie && mantissa % 2 !== 0)) mantissa++;
  return Math.fround(mantissa * divisor);
}
function nscvTextSpanBounds(request: Uint8Array): Uint8Array {
  if (request.length < 24 || request[0] !== 57 || request[1] !== 1 || request[2] !== 0 || request[3] !== 0)
    throw new Error("invalid span bounds header");
  const v = new DataView(request.buffer, request.byteOffset, request.byteLength), count = v.getUint32(4, true);
  if (request.length !== 24 + count * 24 || v.getUint32(20, true) !== 0) throw new Error("invalid span bounds storage");
  const low = v.getUint32(8, true), high = v.getUint32(12, true), height = v.getFloat32(16, true), out = new Uint8Array(20), w = new DataView(out.buffer);
  let present = false, x = 0, y = 0, width = 0;
  let accumulatedHeight = 0;
  for (let i = 0; i < count; i++) {
    const at = 24 + i * 24;
    if (v.getUint32(at, true) !== low || v.getUint32(at + 4, true) !== high) continue;
    const rx = v.getFloat32(at + 16, true), ry = Math.fround(nscvSpanLineFloat(v.getUint32(at + 8, true), v.getUint32(at + 12, true)) * height), rw = v.getFloat32(at + 20, true);
    if (!present) { x = rx; y = ry; width = rw; accumulatedHeight = height; present = true; }
    else {
      const empty = width <= 0 || accumulatedHeight <= 0, nextEmpty = rw <= 0 || height <= 0;
      if (empty && nextEmpty) { x = 0; y = 0; width = 0; accumulatedHeight = 0; }
      else if (empty) { x = rx; y = ry; width = rw; accumulatedHeight = height; }
      else if (!nextEmpty) {
        const left = nscvShellMin(x, rx), top = nscvShellMin(y, ry);
        width = Math.fround(nscvShellMax(Math.fround(x + width), Math.fround(rx + rw)) - left);
        accumulatedHeight = Math.fround(nscvShellMax(Math.fround(y + accumulatedHeight), Math.fround(ry + height)) - top); x = left; y = top;
      }
    }
  }
  if (present) { w.setUint32(0, 1, true); w.setFloat32(4, x, true); w.setFloat32(8, y, true); w.setFloat32(12, width, true); w.setFloat32(16, accumulatedHeight, true); }
  return out;
}
